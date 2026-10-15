# Run in jido_chat/integration with the local all-provider dependency profile.
# Set JIDO_QUEUE_REPORT to the output path. This script uses no network provider.
Mix.Task.run("compile", ["--warnings-as-errors"])

defmodule Jido.Messaging.QueueProbe.Instance do
  use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
end

defmodule Jido.Messaging.QueueProbe.Adapter do
  use Jido.Chat.Adapter, name: :queue_probe

  @impl true
  def signal_protocol, do: 1
  @impl true
  def configure_binding(opts), do: {:ok, opts}
  @impl true
  def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
  @impl true
  def capabilities, do: %{send_message: :native}

  @impl true
  def send_message(_room, text, opts) do
    owner = Keyword.fetch!(opts, :probe_owner)
    send(owner, {:provider_entered, self(), text})

    if text == "hold" do
      receive do
        :release_provider -> :ok
      after
        5_000 -> raise "probe barrier timed out"
      end
    end

    attempt = Process.get({__MODULE__, text}, 0) + 1
    Process.put({__MODULE__, text}, attempt)

    if text == "retry" and attempt == 1 do
      {:error, :network_error}
    else
      send(owner, {:provider_effect, text})
      {:ok, %{message_id: "probe-" <> text}}
    end
  end
end

defmodule Jido.Messaging.QueueProbe do
  alias Jido.Messaging.OutboundGateway
  alias Jido.Messaging.OutboundGateway.Partition
  alias Jido.Messaging.QueueProbe.{Adapter, Instance}

  def run do
    trials = Enum.map(1..3, &trial/1)
    %{workload: %{partitions: 1, capacity: 2, burst: 12, caller_timeout_ms: 20, hold_ms: 100}, trials: trials}
  end

  defp trial(index) do
    Application.put_env(Instance, :outbound_gateway,
      partition_count: 1,
      queue_capacity: 2,
      max_attempts: 1,
      pressure_policy: [shed_action: :none, degraded_action: :none]
    )

    {:ok, supervisor} = Instance.start_link()
    partition = Partition.whereis(Instance, 0)
    owner = self()
    context = %{channel: Adapter, bridge_id: "probe", external_room_id: "room"}
    first = Task.async(fn -> OutboundGateway.send_message(Instance, context, "hold", probe_owner: owner) end)

    receive do
      {:provider_entered, ^partition, "hold"} -> :ok
      {ref, result} when ref == first.ref -> raise "first dispatch returned #{inspect(result)}"
    after
      5_000 -> raise "provider did not start"
    end

    request = %{
      operation: :send,
      channel: Adapter,
      bridge_id: "probe",
      external_room_id: "room",
      routing_key: "probe:room",
      payload: "late",
      session_key: {"probe", "room"},
      opts: [probe_owner: owner],
      priority: :high,
      max_attempts: 1
    }

    late =
      Task.async(fn ->
        try do
          Partition.dispatch(Instance, 0, request, 20)
        catch
          :exit, {:timeout, _} -> :caller_timeout
        end
      end)

    burst =
      Enum.map(1..12, fn number ->
        Task.async(fn ->
          started = System.monotonic_time(:microsecond)
          result = OutboundGateway.send_message(Instance, context, "burst-#{number}", priority: :high)
          %{latency_ms: (System.monotonic_time(:microsecond) - started) / 1_000, outcome: outcome(result)}
        end)
      end)

    await_mailbox(partition, 13, System.monotonic_time(:millisecond) + 5_000)
    Process.sleep(100)
    {:messages, messages} = Process.info(partition, :messages)
    dispatch_backlog = Enum.count(messages, &match?({:"$gen_call", _, {:dispatch, _}}, &1))
    {:memory, memory} = Process.info(partition, :memory)
    caller_result = Task.await(late, 1_000)
    send(partition, :release_provider)
    {:ok, _} = Task.await(first, 5_000)
    results = Enum.map(burst, &Task.await(&1, 5_000))
    # A call barrier makes all provider effects visible before the mailbox drain.
    :sys.get_state(partition)
    effects = drain_effects([])
    latencies = results |> Enum.map(& &1.latency_ms) |> Enum.sort()

    report = %{
      trial: index,
      dispatch_mailbox_while_blocked: dispatch_backlog,
      partition_memory_bytes: memory,
      caller_result: caller_result,
      effect_after_caller_timeout: "late" in effects,
      provider_effects: length(effects),
      outcomes: Enum.frequencies_by(results, & &1.outcome),
      latency_ms: %{p50: Enum.at(latencies, 5), p95: Enum.at(latencies, 11), max: List.last(latencies)},
      retry_wait: retry_wait(context, partition, index)
    }

    Supervisor.stop(supervisor)
    Application.delete_env(Instance, :outbound_gateway)
    report
  end

  defp retry_wait(context, partition, index) do
    owner = self()
    handler = "queue-probe-retry-#{index}"

    :telemetry.attach(
      handler,
      [:jido_messaging, :outbound, :retry_scheduled],
      fn _, measurements, _, parent -> send(parent, {:backoff_started, measurements.next_in_ms}) end,
      owner
    )

    retry =
      Task.async(fn ->
        OutboundGateway.send_message(Instance, context, "retry",
          max_attempts: 2,
          base_backoff_ms: 200,
          max_backoff_ms: 200
        )
      end)

    receive do
      {:backoff_started, 200} -> :ok
    after
      5_000 -> raise "retry did not start"
    end

    later =
      Task.async(fn ->
        started = System.monotonic_time(:microsecond)
        result = OutboundGateway.send_message(Instance, context, "after-retry")
        %{latency_ms: (System.monotonic_time(:microsecond) - started) / 1_000, outcome: outcome(result)}
      end)

    await_mailbox(partition, 1, System.monotonic_time(:millisecond) + 5_000)
    {:message_queue_len, backlog} = Process.info(partition, :message_queue_len)
    {:ok, result} = Task.await(retry, 5_000)
    waited = Task.await(later, 5_000)
    :telemetry.detach(handler)
    drain_effects([])
    %{backoff_ms: 200, dispatch_mailbox_during_backoff: backlog, attempts: result.attempts, later_call: waited}
  end

  defp await_mailbox(partition, count, deadline) do
    {:messages, messages} = Process.info(partition, :messages)
    queued = Enum.count(messages, &match?({:"$gen_call", _, {:dispatch, _}}, &1))

    cond do
      queued >= count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "burst did not enter the mailbox"

      true ->
        Process.sleep(1)
        await_mailbox(partition, count, deadline)
    end
  end

  defp drain_effects(acc) do
    receive do
      {:provider_effect, text} -> drain_effects([text | acc])
      {:provider_entered, _, _} -> drain_effects(acc)
    after
      0 -> acc
    end
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %{reason: reason}}), do: reason
  defp outcome({:error, reason}), do: reason
end

File.write!(System.fetch_env!("JIDO_QUEUE_REPORT"), Jason.encode!(Jido.Messaging.QueueProbe.run(), pretty: true))
