defmodule Jido.Messaging.RuntimeOwnershipTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.{OutboundGateway, RequestLedger, Runtime}
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
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
    @impl true
    def send_message(_room, _text, opts) do
      send(opts[:probe], {:effect_before_reply, self()})

      receive do
        :release -> {:ok, %{id: "sent"}}
      after
        5_000 -> raise "provider barrier was not released"
      end
    end
  end

  setup do
    Application.put_env(Instance, :outbound_gateway, partition_count: 1, max_attempts: 3)
    supervisor = start_supervised!(Instance)
    on_exit(fn -> Application.delete_env(Instance, :outbound_gateway) end)
    %{supervisor: supervisor, runtime: Instance.__jido_messaging__(:runtime)}
  end

  test "core retains its existing process groups; onboarding is optional", %{supervisor: supervisor} do
    ids = child_ids(supervisor)

    for suffix <- [Registry.Rooms, Registry.Agents, Registry.Instances, Registry.Bridges] do
      assert Module.concat(Instance, suffix) in ids
    end

    for child <- [
          Runtime,
          Jido.Messaging.SubscriptionSupervisor,
          Jido.Messaging.RoomSupervisor,
          Jido.Messaging.AgentSupervisor,
          Jido.Messaging.SessionManager.Supervisor,
          Jido.Messaging.DeadLetter,
          Jido.Messaging.DeadLetter.ReplaySupervisor,
          Jido.Messaging.OutboundGateway.Supervisor,
          Jido.Messaging.ConfigStore,
          Jido.Messaging.Deduper,
          Jido.Messaging.InstanceSupervisor,
          Jido.Messaging.BridgeSupervisor
        ] do
      assert child in ids
    end

    refute Process.whereis(Module.concat(Instance, OnboardingSupervisor))
    refute Process.whereis(Module.concat(Instance, Registry.Onboarding))
  end

  test "Runtime owns request and created-binding tables; external bindings keep their owner", %{
    supervisor: supervisor,
    runtime: runtime
  } do
    owner = Process.whereis(runtime)
    table = Runtime.request_table(runtime)
    {:ok, created} = Runtime.ensure_binding(runtime, Adapter, "created", [])
    {:ok, external} = Jido.Chat.bind(Adapter, id: "external")
    :ok = Runtime.register_binding(runtime, external)
    assert :ets.info(table, :owner) == owner
    assert :ets.info(created.resources, :owner) == owner
    assert :ets.info(external.resources, :owner) == self()
    assert {:ok, claim} = RequestLedger.claim(table, {"principal", "request"}, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, :result)

    :ok = Supervisor.terminate_child(supervisor, Runtime)
    assert :ets.info(table) == :undefined
    assert :ets.info(created.resources) == :undefined
    assert :ets.info(external.resources, :owner) == self()
    assert {:ok, restarted} = Supervisor.restart_child(supervisor, Runtime)
    assert restarted != owner
    replacement = Runtime.request_table(runtime)
    assert :ets.info(replacement, :size) == 1
    assert {:ok, _} = RequestLedger.claim(replacement, {"principal", "request"}, :payload, :authority)
    assert {:error, :binding_not_found} = Runtime.binding(runtime, "created")
    assert {:error, :binding_not_found} = Runtime.binding(runtime, "external")
  end

  test "Bus restart loses ordinary subscriptions and leaves Runtime alive", %{supervisor: supervisor, runtime: runtime} do
    name = Jido.Messaging.Supervisor.signal_bus_name(Instance)
    {:ok, bus} = Jido.Signal.Bus.whereis(name)
    runtime_pid = Process.whereis(runtime)
    {:ok, id} = Jido.Signal.Bus.subscribe(name, "ownership.probe")
    assert Map.has_key?(:sys.get_state(bus).subscriptions, id)
    bus_id = Supervisor.which_children(supervisor) |> Enum.find_value(fn {id, pid, _, _} -> if pid == bus, do: id end)
    :ok = Supervisor.terminate_child(supervisor, bus_id)
    {:ok, replacement} = Supervisor.restart_child(supervisor, bus_id)
    refute replacement == bus
    assert Process.whereis(runtime) == runtime_pid
    assert :sys.get_state(replacement).subscriptions == %{}
    assert {:ok, new_id} = Jido.Signal.Bus.subscribe(name, "ownership.probe")
    assert Map.has_key?(:sys.get_state(replacement).subscriptions, new_id)
  end

  test "registry loss restarts registered gateway partitions", %{runtime: runtime} do
    registry = Module.concat(Instance, Registry.Instances)
    owner = Process.whereis(registry)
    partition = Partition.whereis(Instance, 0)
    runtime_pid = Process.whereis(runtime)
    table = Runtime.request_table(runtime)
    Process.exit(owner, :kill)

    eventually(fn ->
      registry_pid = Process.whereis(registry)
      is_pid(registry_pid) and registry_pid != owner
    end)

    eventually(fn ->
      try do
        replacement = Partition.whereis(Instance, 0)

        is_pid(replacement) and replacement != partition and
          match?({:ok, _, _}, Jido.Messaging.OutboundGateway.Admission.snapshot(Instance, 0, replacement))
      rescue
        ArgumentError -> false
      end
    end)

    recovered_runtime = Process.whereis(runtime)
    assert is_pid(recovered_runtime)
    assert :ets.info(Runtime.request_table(runtime), :owner) == recovered_runtime
    assert recovered_runtime == runtime_pid
    assert :ets.info(table, :owner) == runtime_pid
  end

  test "provider effect followed by partition death stays unknown and is not retried", %{runtime: runtime} do
    context = %{channel: Adapter, bridge_id: "uncertain", external_room_id: "room"}
    caller = self()

    task =
      Task.async(fn ->
        try do
          OutboundGateway.send_message(Instance, context, "hello", request_id: "uncertain-id", probe: caller)
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    assert_receive {:effect_before_reply, worker}, 1_000
    partition = Partition.whereis(Instance, 0)
    monitor = Process.monitor(worker)
    Process.exit(partition, :kill)
    assert {:caller_exit, _} = Task.await(task, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000

    eventually(fn ->
      replacement = Partition.whereis(Instance, 0)

      is_pid(replacement) and replacement != partition and
        match?({:ok, _, _}, Jido.Messaging.OutboundGateway.Admission.snapshot(Instance, 0, replacement))
    end)

    assert {:ok, binding} = Runtime.binding(runtime, "uncertain")
    assert :ets.info(binding.resources) != :undefined

    assert {:error, error} =
             OutboundGateway.send_message(Instance, context, "hello", request_id: "uncertain-id", probe: caller)

    assert %Contract{code: :request_outcome_unknown} = error.reason
    assert error.attempt == 1
    assert error.retryable == false
    refute_receive {:effect_before_reply, _}
  end

  defp child_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {id, pid, :supervisor, _} when is_pid(pid) -> [id | child_ids(pid)]
      {id, _pid, _type, _modules} -> [id]
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("process did not recover")

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
