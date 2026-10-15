defmodule Jido.Messaging.GatewayCoordinatorTest do
  use ExUnit.Case, async: false
  import Jido.Messaging.TestHelpers
  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.{OutboundGateway, Runtime}
  alias Jido.Messaging.OutboundGateway.Partition

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: {:error, :unused}
    @impl true
    def capabilities, do: %{send_message: :native, send_file: :native, delete_message: :native}
    @impl true
    def send_message(_room, text, opts) do
      attempt =
        Agent.get_and_update(opts[:control], fn counts ->
          count = Map.get(counts, text, 0) + 1
          {count, Map.put(counts, text, count)}
        end)

      send(opts[:probe], {:entered, self(), text, attempt})
      if text == "held", do: receive(do: (:release -> :ok))

      cond do
        text == "retry" and attempt == 1 -> {:error, :network_error}
        text == "large" -> {:ok, %{id: "large", text: String.duplicate("large", 60_000)}}
        true -> {:ok, %{id: text}}
      end
    end

    @impl true
    def send_file(_room, file, opts) do
      send(opts[:probe], {:file, self(), file})
      {:ok, %{id: "uploaded"}}
    end

    @impl true
    def delete_message(_room, _id, opts) do
      send(opts[:probe], {:deleted, self()})
      {:error, :timeout}
    end
  end

  setup context do
    opts =
      Keyword.merge(
        [
          partition_count: 1,
          queue_capacity: 2,
          max_attempts: 3,
          base_backoff_ms: 60_000,
          max_backoff_ms: 60_000,
          pressure_policy: [shed_action: :none, degraded_action: :none]
        ],
        context[:gateway] || []
      )

    Application.put_env(Instance, :outbound_gateway, opts)
    on_exit(fn -> Application.delete_env(Instance, :outbound_gateway) end)
    start_supervised!(Instance)
    control = start_supervised!({Agent, fn -> %{} end})
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, binding} = Runtime.ensure_binding(runtime, Adapter, "test", probe: self(), control: control)

    %{
      partition: Partition.whereis(Instance, 0),
      runtime: runtime,
      binding: binding,
      context: %{channel: Adapter, bridge_id: "test", external_room_id: "room"}
    }
  end

  test "admission runs while a provider waits and FIFO survives caller timeout", context do
    first = Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "held") end)
    assert_receive {:entered, worker, "held", 1}, 1_000
    assert worker != context.partition

    later =
      Task.async(fn ->
        try do
          Partition.dispatch(Instance, 0, request("later"), 20)
        catch
          :exit, {:timeout, _} -> :caller_timeout
        end
      end)

    assert_eventually(fn -> :sys.get_state(context.partition).queue_size == 1 end, timeout: 1_000)
    assert Task.await(later) == :caller_timeout
    assert {:error, %{reason: :queue_full}} = OutboundGateway.send_message(Instance, context.context, "rejected")
    refute_received {:entered, _, "later", _}
    send(worker, :release)
    assert {:ok, _} = Task.await(first)
    assert_receive {:entered, _, "later", 1}, 1_000
    assert_eventually(fn -> :sys.get_state(context.partition).processing == false end, timeout: 1_000)
  end

  test "retry timers retain the job and process admission without provider parallelism", context do
    first = Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "retry") end)
    assert_receive {:entered, _, "retry", 1}, 1_000
    assert_eventually(fn -> is_reference(:sys.get_state(context.partition).active.timer) end, timeout: 1_000)
    timer = :sys.get_state(context.partition).active.timer
    later = Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "later") end)
    assert_eventually(fn -> :sys.get_state(context.partition).queue_size == 1 end, timeout: 1_000)
    assert {:error, %{reason: :queue_full}} = OutboundGateway.send_message(Instance, context.context, "rejected")
    refute_received {:entered, _, "later", _}
    send(context.partition, {:continue_job, timer})
    assert {:ok, %{attempts: 2}} = Task.await(first)
    assert_receive {:entered, _, "retry", 2}, 1_000
    assert {:ok, _} = Task.await(later)
    assert_receive {:entered, _, "later", 1}, 1_000
    send(context.partition, {:continue_job, timer})
    assert :sys.get_state(context.partition).active == nil
    refute_received {:entered, _, _, _}
  end

  @tag gateway: [
         queue_capacity: 4,
         pressure_policy: [
           warn_ratio: 0.05,
           degraded_ratio: 0.1,
           shed_ratio: 0.99,
           degraded_action: :throttle,
           degraded_throttle_ms: 60_000,
           shed_action: :none
         ]
       ]
  test "pressure throttle waits use a timer and leave admission responsive", context do
    first = Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "first") end)

    assert_eventually(
      fn ->
        state = :sys.get_state(context.partition)
        state.active != nil and is_reference(state.active.timer)
      end,
      timeout: 1_000
    )

    timer = :sys.get_state(context.partition).active.timer
    later = Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "later") end)
    assert_eventually(fn -> :sys.get_state(context.partition).queue_size == 1 end, timeout: 1_000)
    refute_received {:entered, _, _, _}
    send(context.partition, {:continue_job, timer})
    assert {:ok, _} = Task.await(first)
    assert_receive {:entered, _, "first", 1}, 1_000

    assert_eventually(
      fn ->
        state = :sys.get_state(context.partition)
        state.active != nil and is_reference(state.active.timer)
      end,
      timeout: 1_000
    )

    send(context.partition, {:continue_job, :sys.get_state(context.partition).active.timer})
    assert {:ok, _} = Task.await(later)
    assert_receive {:entered, _, "later", 1}, 1_000
  end

  test "worker death after an effect is unknown and late messages cannot finish another job", context do
    first =
      Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "held", request_id: "uncertain") end)

    assert_receive {:entered, worker, "held", 1}, 1_000
    active = :sys.get_state(context.partition).active
    Process.exit(worker, :kill)
    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}, attempt: 1}} = Task.await(first)
    assert Process.alive?(context.partition)

    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}, attempt: 1}} =
             OutboundGateway.send_message(Instance, context.context, "held", request_id: "uncertain")

    next = Task.async(fn -> OutboundGateway.send_message(Instance, context.context, "held", request_id: "next") end)
    assert_receive {:entered, next_worker, "held", 2}, 1_000
    send(context.partition, {:provider_result, active.worker_tag, {:ok, %{id: "late"}}})
    send(context.partition, {:DOWN, active.monitor, :process, worker, :normal})
    assert :sys.get_state(context.partition).active.worker == next_worker
    send(next_worker, :release)
    assert {:ok, %{message_id: "held"}} = Task.await(next)
  end

  test "caller death does not cancel accepted provider work", context do
    caller = spawn(fn -> OutboundGateway.send_message(Instance, context.context, "held", request_id: "orphan") end)
    assert_receive {:entered, worker, "held", 1}, 1_000
    Process.exit(caller, :kill)
    assert Process.alive?(worker)
    send(worker, :release)
    assert_eventually(fn -> :sys.get_state(context.partition).active == nil end, timeout: 1_000)
    assert {:ok, _} = OutboundGateway.send_message(Instance, context.context, "held", request_id: "orphan")
    refute_received {:entered, _, _, _}
  end

  test "replacement waits for the old worker group and retains large result ownership", context do
    assert {:ok, response} = OutboundGateway.send_message(Instance, context.context, "large", request_id: "large")
    ref = response.result["resource_ref"]

    assert [{{:resource, _}, owner, "result", _, _, :active}] =
             :ets.lookup(context.binding.resources, {:resource, ref["id"]})

    assert owner == context.partition

    task =
      Task.async(fn ->
        try do
          OutboundGateway.send_message(Instance, context.context, "held", request_id: "interrupted")
        catch
          :exit, _ -> :partition_exit
        end
      end)

    assert_receive {:entered, worker, "held", 1}, 1_000
    worker_monitor = Process.monitor(worker)
    old_workers = :sys.get_state(context.partition).workers
    Process.exit(context.partition, :kill)
    assert Task.await(task) == :partition_exit
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000

    assert_eventually(
      fn ->
        pid = Partition.whereis(Instance, 0)
        is_pid(pid) and pid != context.partition and :sys.get_state(pid).active == nil
      end,
      timeout: 1_000
    )

    assert not Process.alive?(old_workers)
    assert {:ok, replay} = OutboundGateway.send_message(Instance, context.context, "large", request_id: "large")
    assert replay.result == response.result
    assert {:error, %Contract{code: :resource_expired}} = Jido.Chat.Resources.resolve(context.binding, ref)

    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}}} =
             OutboundGateway.send_message(Instance, context.context, "held", request_id: "interrupted")
  end

  test "media upload and delete complete under the coordinator with stable stage IDs", context do
    payload = %{kind: :image, data: "complete"}
    assert {:ok, result} = OutboundGateway.edit_media(Instance, context.context, "old", payload, request_id: "replace")
    assert result.message_id == "uploaded"
    assert result.result.metadata.replacement.delete_status == :delete_failed
    assert_receive {:file, worker, %Jido.Chat.FileUpload{data: "complete"}}, 1_000
    assert_receive {:deleted, delete_worker}, 1_000
    assert worker != context.partition
    assert delete_worker != worker

    for {{:resource, _}, owner, _, _, _, _} <- :ets.tab2list(context.binding.resources),
        do: assert(owner == context.partition)

    assert {:ok, _} = OutboundGateway.edit_media(Instance, context.context, "old", payload, request_id: "replace")
    refute_received {:file, _, _}
    refute_received {:deleted, _}
  end

  test "partition shutdown stops the active worker before a queued provider can start", context do
    first =
      Task.async(fn ->
        try do
          OutboundGateway.send_message(Instance, context.context, "held", request_id: "shutdown-active")
        catch
          :exit, _ -> :stopped
        end
      end)

    assert_receive {:entered, worker, "held", 1}, 1_000

    queued =
      Task.async(fn ->
        try do
          OutboundGateway.send_message(Instance, context.context, "queued", request_id: "shutdown-queued")
        catch
          :exit, _ -> :stopped
        end
      end)

    assert_eventually(fn -> :sys.get_state(context.partition).queue_size == 1 end, timeout: 1_000)
    monitor = Process.monitor(worker)
    gateway = Module.concat(Instance, OutboundGatewaySupervisor)
    :ok = Supervisor.terminate_child(gateway, {:outbound_gateway_partition, 0})
    assert Task.await(first) == :stopped
    assert Task.await(queued) == :stopped
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    refute_received {:entered, _, "queued", _}
    assert {:ok, _} = Supervisor.restart_child(gateway, {:outbound_gateway_partition, 0})
    assert {:ok, _} = OutboundGateway.send_message(Instance, context.context, "queued", request_id: "shutdown-queued")
    assert_receive {:entered, _, "queued", 1}, 1_000

    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}}} =
             OutboundGateway.send_message(Instance, context.context, "held", request_id: "shutdown-active")
  end

  defp request(text),
    do: %{
      operation: :send,
      channel: Adapter,
      bridge_id: "test",
      external_room_id: "room",
      payload: text,
      opts: [],
      priority: :high,
      routing_key: "test:room",
      max_attempts: 1
    }
end
