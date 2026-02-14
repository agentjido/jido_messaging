defmodule JidoMessaging.InstanceReconnectWorker do
  @moduledoc """
  Per-instance lifecycle worker that runs connection probes and reconnect policy.

  The worker performs periodic health probes and schedules bounded reconnect
  attempts on recoverable failures. When retries are exhausted, it exits so the
  enclosing supervisor can apply restart intensity policy.
  """
  use GenServer

  alias JidoMessaging.{Adapters.Heartbeat, Channel, Instance, InstanceServer}

  @default_max_reconnect_attempts 5
  @default_reconnect_base_backoff_ms 250
  @default_reconnect_max_backoff_ms 5_000
  @default_reconnect_jitter_ratio 0.2

  @type state :: %{
          instance_module: module(),
          instance: Instance.t(),
          instance_server: pid(),
          channel_module: module() | nil,
          phase: :starting | :connected | :disconnected | :reconnecting | :degraded,
          probe_interval_ms: pos_integer(),
          max_reconnect_attempts: pos_integer(),
          reconnect_base_backoff_ms: pos_integer(),
          reconnect_max_backoff_ms: pos_integer(),
          reconnect_jitter_ratio: float(),
          current_attempt: non_neg_integer(),
          reconnect_reason: term() | nil,
          reconnect_started_at_ms: integer() | nil,
          timer_ref: reference() | nil
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    instance = Keyword.fetch!(opts, :instance)
    instance_server = Keyword.fetch!(opts, :instance_server)
    channel_module = Keyword.get(opts, :channel_module)

    settings = normalize_settings(instance.settings)
    probe_interval_ms = setting(settings, :probe_interval_ms, default_probe_interval(channel_module))

    state = %{
      instance_module: instance_module,
      instance: instance,
      instance_server: instance_server,
      channel_module: channel_module,
      phase: :starting,
      probe_interval_ms: sanitize_positive_integer(probe_interval_ms, default_probe_interval(channel_module)),
      max_reconnect_attempts:
        sanitize_positive_integer(
          setting(settings, :max_reconnect_attempts, @default_max_reconnect_attempts),
          @default_max_reconnect_attempts
        ),
      reconnect_base_backoff_ms:
        sanitize_positive_integer(
          setting(settings, :reconnect_base_backoff_ms, @default_reconnect_base_backoff_ms),
          @default_reconnect_base_backoff_ms
        ),
      reconnect_max_backoff_ms:
        sanitize_positive_integer(
          setting(settings, :reconnect_max_backoff_ms, @default_reconnect_max_backoff_ms),
          @default_reconnect_max_backoff_ms
        ),
      reconnect_jitter_ratio:
        sanitize_jitter_ratio(setting(settings, :reconnect_jitter_ratio, @default_reconnect_jitter_ratio)),
      current_attempt: 0,
      reconnect_reason: nil,
      reconnect_started_at_ms: nil,
      timer_ref: nil
    }

    {:ok, schedule_probe(state)}
  end

  @impl true
  def handle_info(:probe, state) do
    state = %{state | timer_ref: nil}

    case check_health(state) do
      :ok ->
        InstanceServer.notify_connected(state.instance_server, %{attempts: 0, reason: :probe})
        InstanceServer.notify_reconnect_attempt(state.instance_server, 0, nil)

        {:noreply,
         state
         |> reset_reconnect_state(:connected)
         |> schedule_probe()}

      {:error, reason} ->
        class = Channel.classify_failure(reason)

        emit_event(:health_probe, %{}, state, %{
          failure_class: class,
          reason: reason,
          outcome: :error
        })

        InstanceServer.notify_disconnected(state.instance_server, reason)

        case class do
          :recoverable ->
            {:noreply, start_reconnect(state, reason)}

          :degraded ->
            InstanceServer.notify_reconnect_attempt(state.instance_server, 0, reason)

            {:noreply,
             state
             |> reset_reconnect_state(:degraded)
             |> schedule_probe()}

          :fatal ->
            InstanceServer.notify_failure(state.instance_server, reason)
            InstanceServer.notify_restart_marker(state.instance_server, :fatal, reason)

            {:stop, {:shutdown, {:fatal_probe, reason}}, state}
        end
    end
  end

  @impl true
  def handle_info({:reconnect, attempt, original_reason, started_at_ms}, state) do
    state = %{state | timer_ref: nil}
    InstanceServer.notify_connecting(state.instance_server)
    InstanceServer.notify_reconnect_attempt(state.instance_server, attempt, original_reason)

    emit_event(:reconnect_attempt, %{attempt: attempt}, state, %{reason: original_reason})

    case check_health(state) do
      :ok ->
        elapsed_ms = elapsed_ms(started_at_ms)

        InstanceServer.notify_connected(state.instance_server, %{
          attempts: attempt,
          reason: original_reason,
          elapsed_ms: elapsed_ms
        })

        InstanceServer.notify_reconnect_attempt(state.instance_server, 0, nil)

        {:noreply,
         state
         |> reset_reconnect_state(:connected)
         |> schedule_probe()}

      {:error, reason} ->
        class = Channel.classify_failure(reason)

        emit_event(:reconnect_failed, %{attempt: attempt}, state, %{
          failure_class: class,
          reason: reason
        })

        case class do
          :recoverable when attempt < state.max_reconnect_attempts ->
            next_attempt = attempt + 1
            delay_ms = calculate_backoff(next_attempt, state)

            emit_event(
              :reconnect_scheduled,
              %{attempt: next_attempt, delay_ms: delay_ms},
              state,
              %{
                reason: reason,
                failure_class: :recoverable
              }
            )

            timer_ref =
              Process.send_after(self(), {:reconnect, next_attempt, original_reason, started_at_ms}, delay_ms)

            {:noreply,
             %{
               state
               | phase: :reconnecting,
                 current_attempt: next_attempt,
                 reconnect_reason: reason,
                 timer_ref: timer_ref
             }}

          :recoverable ->
            emit_event(
              :reconnect_exhausted,
              %{attempt: attempt},
              state,
              %{reason: reason, failure_class: :recoverable}
            )

            InstanceServer.notify_failure(state.instance_server, {:reconnect_exhausted, reason})
            InstanceServer.notify_restart_marker(state.instance_server, :recoverable, reason)

            {:stop, {:shutdown, :reconnect_exhausted}, state}

          :degraded ->
            InstanceServer.notify_disconnected(state.instance_server, reason)

            {:noreply,
             state
             |> reset_reconnect_state(:degraded)
             |> schedule_probe()}

          :fatal ->
            InstanceServer.notify_failure(state.instance_server, reason)
            InstanceServer.notify_restart_marker(state.instance_server, :fatal, reason)

            {:stop, {:shutdown, {:fatal_reconnect, reason}}, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  # Internal helpers

  defp start_reconnect(state, reason) do
    started_at_ms = monotonic_ms()
    first_attempt = 1
    delay_ms = calculate_backoff(first_attempt, state)

    emit_event(
      :reconnect_scheduled,
      %{attempt: first_attempt, delay_ms: delay_ms},
      state,
      %{reason: reason, failure_class: :recoverable}
    )

    timer_ref = Process.send_after(self(), {:reconnect, first_attempt, reason, started_at_ms}, delay_ms)

    %{
      state
      | phase: :reconnecting,
        current_attempt: first_attempt,
        reconnect_reason: reason,
        reconnect_started_at_ms: started_at_ms,
        timer_ref: timer_ref
    }
  end

  defp schedule_probe(state) do
    cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :probe, state.probe_interval_ms)
    %{state | timer_ref: timer_ref}
  end

  defp reset_reconnect_state(state, phase) do
    %{
      state
      | phase: phase,
        current_attempt: 0,
        reconnect_reason: nil,
        reconnect_started_at_ms: nil
    }
  end

  defp check_health(%{channel_module: nil}) do
    :ok
  end

  defp check_health(state) do
    result =
      try do
        Heartbeat.check_health(state.channel_module, state.instance)
      rescue
        exception ->
          {:error, {:exception, exception}}
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp calculate_backoff(attempt, state) do
    base_ms = round(state.reconnect_base_backoff_ms * :math.pow(2, max(attempt - 1, 0)))
    capped_ms = min(base_ms, state.reconnect_max_backoff_ms)
    jitter_span = round(capped_ms * state.reconnect_jitter_ratio)

    if jitter_span <= 0 do
      capped_ms
    else
      jitter = :rand.uniform(jitter_span * 2 + 1) - (jitter_span + 1)
      max(1, capped_ms + jitter)
    end
  end

  defp elapsed_ms(nil), do: 0
  defp elapsed_ms(started_at_ms), do: max(monotonic_ms() - started_at_ms, 0)

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp emit_event(event, measurements, state, metadata) do
    :telemetry.execute(
      [:jido_messaging, :instance, event],
      measurements,
      Map.merge(
        %{
          instance_id: state.instance.id,
          channel_type: state.instance.channel_type,
          instance_module: state.instance_module
        },
        metadata
      )
    )
  end

  defp default_probe_interval(nil), do: :timer.seconds(30)
  defp default_probe_interval(channel_module), do: Heartbeat.probe_interval_ms(channel_module)

  defp normalize_settings(settings) when is_map(settings), do: settings
  defp normalize_settings(_), do: %{}

  defp setting(settings, key, default) do
    case Map.fetch(settings, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(settings, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  defp sanitize_positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp sanitize_positive_integer(_value, fallback), do: fallback

  defp sanitize_jitter_ratio(value) when is_float(value) and value >= 0.0 and value <= 1.0, do: value
  defp sanitize_jitter_ratio(value) when is_integer(value) and value >= 0 and value <= 1, do: value / 1
  defp sanitize_jitter_ratio(_value), do: @default_reconnect_jitter_ratio

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end
end
