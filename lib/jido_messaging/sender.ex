defmodule JidoMessaging.Sender do
  @moduledoc """
  Per-instance message sender with retry queue and exponential backoff.

  Handles outbound message delivery with:
  - Queued delivery (non-blocking for callers)
  - Exponential backoff with jitter on failures
  - Configurable max attempts
  - Telemetry signals for delivery lifecycle

  ## Signals Emitted

  - `[:jido_messaging, :delivery, :queued]`
  - `[:jido_messaging, :delivery, :attempt]`
  - `[:jido_messaging, :delivery, :retry_scheduled]`
  - `[:jido_messaging, :delivery, :gave_up]`
  """
  use GenServer
  require Logger

  @default_max_attempts 5
  @default_base_backoff_ms 500
  @default_max_backoff_ms 30_000
  @max_queue_size 1000

  defstruct [
    :instance_module,
    :instance_id,
    :channel,
    :instance_server,
    queue: :queue.new(),
    queue_size: 0,
    max_attempts: @default_max_attempts,
    base_backoff_ms: @default_base_backoff_ms,
    max_backoff_ms: @default_max_backoff_ms
  ]

  @type delivery_job :: %{
          id: String.t(),
          message_id: String.t(),
          external_room_id: term(),
          payload: String.t(),
          attempts: non_neg_integer(),
          next_attempt_at: integer() | nil,
          metadata: map()
        }

  # Client API

  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    instance_id = Keyword.fetch!(opts, :instance_id)
    name = via_tuple(instance_module, instance_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the sender pid for an instance"
  def whereis(instance_module, instance_id) do
    case Registry.lookup(registry_name(instance_module), {:sender, instance_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Enqueue a message for delivery.

  Returns `{:ok, job_id}` if queued successfully, `{:error, :queue_full}` if at capacity.
  """
  @spec enqueue(pid(), String.t(), term(), String.t(), map()) ::
          {:ok, String.t()} | {:error, :queue_full}
  def enqueue(pid, message_id, external_room_id, payload, metadata \\ %{}) do
    GenServer.call(pid, {:enqueue, message_id, external_room_id, payload, metadata})
  end

  @doc "Get current queue size"
  @spec queue_size(pid()) :: non_neg_integer()
  def queue_size(pid) do
    GenServer.call(pid, :queue_size)
  end

  defp via_tuple(instance_module, instance_id) do
    {:via, Registry, {registry_name(instance_module), {:sender, instance_id}}}
  end

  defp registry_name(instance_module) do
    Module.concat(instance_module, Registry.Instances)
  end

  # Server implementation

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    instance_id = Keyword.fetch!(opts, :instance_id)
    channel = Keyword.fetch!(opts, :channel)
    instance_server = Keyword.get(opts, :instance_server)

    state = %__MODULE__{
      instance_module: instance_module,
      instance_id: instance_id,
      channel: channel,
      instance_server: instance_server,
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, message_id, external_room_id, payload, metadata}, _from, state) do
    if state.queue_size >= @max_queue_size do
      {:reply, {:error, :queue_full}, state}
    else
      job = %{
        id: generate_job_id(),
        message_id: message_id,
        external_room_id: external_room_id,
        payload: payload,
        attempts: 0,
        next_attempt_at: nil,
        metadata: metadata
      }

      new_queue = :queue.in(job, state.queue)
      new_state = %{state | queue: new_queue, queue_size: state.queue_size + 1}

      emit_signal(state, :queued, %{
        message_id: message_id,
        instance_id: state.instance_id,
        job_id: job.id
      })

      send(self(), :process_queue)

      {:reply, {:ok, job.id}, new_state}
    end
  end

  @impl true
  def handle_call(:queue_size, _from, state) do
    {:reply, state.queue_size, state}
  end

  @impl true
  def handle_info(:process_queue, state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {:noreply, state}

      {{:value, job}, remaining_queue} ->
        now = System.monotonic_time(:millisecond)

        if job.next_attempt_at && job.next_attempt_at > now do
          delay = job.next_attempt_at - now
          Process.send_after(self(), {:retry, job}, delay)
          {:noreply, %{state | queue: remaining_queue, queue_size: state.queue_size - 1}}
        else
          new_state = %{state | queue: remaining_queue, queue_size: state.queue_size - 1}
          attempt_delivery(job, new_state)
        end
    end
  end

  @impl true
  def handle_info({:retry, job}, state) do
    attempt_delivery(job, state)
  end

  defp attempt_delivery(job, state) do
    attempt = job.attempts + 1

    emit_signal(state, :attempt, %{
      message_id: job.message_id,
      instance_id: state.instance_id,
      job_id: job.id,
      attempt: attempt
    })

    case state.channel.send_message(job.external_room_id, job.payload, []) do
      {:ok, _result} ->
        if state.instance_server do
          JidoMessaging.InstanceServer.notify_success(state.instance_server)
        end

        Logger.debug("[JidoMessaging.Sender] Delivered message #{job.message_id} (attempt #{attempt})")

        send(self(), :process_queue)
        {:noreply, state}

      {:error, reason} ->
        handle_delivery_failure(job, attempt, reason, state)
    end
  end

  defp handle_delivery_failure(job, attempt, reason, state) do
    if state.instance_server do
      JidoMessaging.InstanceServer.notify_failure(state.instance_server, reason)
    end

    if attempt >= state.max_attempts do
      emit_signal(state, :gave_up, %{
        message_id: job.message_id,
        instance_id: state.instance_id,
        job_id: job.id,
        attempts: attempt,
        final_reason: reason
      })

      Logger.warning(
        "[JidoMessaging.Sender] Gave up on message #{job.message_id} after #{attempt} attempts: #{inspect(reason)}"
      )

      send(self(), :process_queue)
      {:noreply, state}
    else
      backoff_ms = calculate_backoff(attempt, state)

      emit_signal(state, :retry_scheduled, %{
        message_id: job.message_id,
        instance_id: state.instance_id,
        job_id: job.id,
        attempt: attempt,
        next_in_ms: backoff_ms,
        reason: reason
      })

      Logger.debug("[JidoMessaging.Sender] Scheduling retry for message #{job.message_id} in #{backoff_ms}ms")

      updated_job = %{
        job
        | attempts: attempt,
          next_attempt_at: System.monotonic_time(:millisecond) + backoff_ms
      }

      Process.send_after(self(), {:retry, updated_job}, backoff_ms)

      {:noreply, state}
    end
  end

  defp calculate_backoff(attempt, state) do
    base = state.base_backoff_ms * :math.pow(2, attempt - 1)
    capped = min(base, state.max_backoff_ms)
    jitter = :rand.uniform() * 0.2 * capped
    round(capped + jitter)
  end

  defp emit_signal(state, event, metadata) do
    :telemetry.execute(
      [:jido_messaging, :delivery, event],
      %{system_time: System.system_time()},
      Map.put(metadata, :instance_module, state.instance_module)
    )
  end

  defp generate_job_id do
    "job_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
