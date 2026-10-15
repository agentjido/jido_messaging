defmodule Jido.Messaging.RegistryIsolationTest do
  use ExUnit.Case, async: false
  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.{InstanceServer, OutboundGateway, RequestLedger, Runtime, SessionManager}
  alias Jido.Messaging.{DesiredWorkers, InstanceSupervisor}
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
    def normalize_event(binding, _), do: Jido.Chat.Delivery.new(binding, "empty", [])
    @impl true
    def send_message(_room, _text, opts) do
      send(opts[:probe], {:provider_effect, self()})

      if opts[:hold] do
        receive do
          :release -> :ok
        after
          5_000 -> raise "provider barrier was not released"
        end
      end

      {:ok, %{id: "sent"}}
    end
  end

  setup do
    Application.put_env(Instance, :outbound_gateway, partition_count: 64)
    Application.put_env(Instance, :session_manager, partition_count: 64)

    on_exit(fn ->
      Application.delete_env(Instance, :outbound_gateway)
      Application.delete_env(Instance, :session_manager)
    end)

    root = start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    %{root: root, runtime: runtime, runtime_pid: Process.whereis(runtime), bus: bus}
  end

  test "registry loss restores 128 partitions and desired provider instances", context do
    {:ok, room} = Instance.create_room(%{name: "retained", type: :group})
    {:ok, provider} = Instance.start_instance(:internal, %{name: "retained-provider"})
    server = InstanceServer.whereis(Instance, provider.id)
    gateway = Partition.whereis(Instance, 0)
    session = SessionManager.partition_pid(Instance, 0)
    table = Runtime.request_table(context.runtime)
    {:ok, claim} = RequestLedger.claim(table, :completed, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, :original_result)
    target = %{channel: Adapter, bridge_id: "completed", external_room_id: "room"}
    assert {:ok, _} = OutboundGateway.send_message(Instance, target, "hello", request_id: "completed", probe: self())
    assert_receive {:provider_effect, _}

    kill_registry()
    assert_recovered(context)
    assert Partition.whereis(Instance, 0) != gateway
    assert SessionManager.partition_pid(Instance, 0) != session

    assert_eventually(
      fn ->
        replacement = InstanceServer.whereis(Instance, provider.id)
        is_pid(replacement) and replacement != server
      end,
      timeout: 2_000
    )

    assert {:ok, ^room} = Instance.get_room(room.id)
    assert Runtime.request_table(context.runtime) == table
    assert {:cached, :original_result} = RequestLedger.claim(table, :completed, :payload, :authority)
    assert {:ok, _} = OutboundGateway.send_message(Instance, target, "hello", request_id: "completed", probe: self())
    refute_receive {:provider_effect, _}
    assert Instance.count_instances() == 1
    assert [%{instance_id: id}] = Instance.list_instances()
    assert id == provider.id
  end

  test "an effect interrupted by registry loss remains unknown", context do
    observer = self()
    target = %{channel: Adapter, bridge_id: "uncertain", external_room_id: "room"}

    task =
      Task.async(fn ->
        try do
          OutboundGateway.send_message(Instance, target, "hello", request_id: "uncertain", hold: true, probe: observer)
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    assert_receive {:provider_effect, _}, 1_000
    kill_registry()
    assert {:caller_exit, _} = Task.await(task, 2_000)
    assert_recovered(context)

    assert {:error, error} =
             OutboundGateway.send_message(Instance, target, "hello", request_id: "uncertain", probe: self())

    assert %{code: :request_outcome_unknown} = error.reason
    assert error.attempt == 1
    refute error.retryable
    refute_receive {:provider_effect, _}
  end

  test "explicit stop removes a desired instance before recovery", context do
    {:ok, stopped} = Instance.start_instance(:internal, %{name: "stopped"})
    {:ok, retained} = Instance.start_instance(:internal, %{name: "retained"})
    assert :ok = Instance.stop_instance(stopped.id)
    kill_registry()
    assert_recovered(context)
    assert_eventually(fn -> is_pid(InstanceServer.whereis(Instance, retained.id)) end, timeout: 2_000)
    refute InstanceServer.whereis(Instance, stopped.id)
    assert Instance.count_instances() == 1
    assert {:error, :not_found} = Instance.stop_instance(stopped.id)
  end

  test "calls during group shutdown use existing unavailable result forms", context do
    registry = Module.concat(Instance, Registry.Instances)
    :ok = Supervisor.terminate_child(context.root, registry)
    assert Partition.whereis(Instance, 0) == nil
    assert SessionManager.partition_pid(Instance, 0) == nil
    assert InstanceServer.whereis(Instance, "missing") == nil
    assert Instance.list_instances() == []
    assert Jido.Messaging.InstanceSupervisor.list_instance_health(Instance) == []
    assert Instance.count_instances() == 0
    assert {:error, :not_found} = Instance.instance_status("missing")

    assert {:error, :partition_unavailable} =
             SessionManager.set(Instance, {:internal, "bridge", "room", nil}, %{external_room_id: "room"})

    assert {:error, error} =
             OutboundGateway.send_message(
               Instance,
               %{channel: Adapter, bridge_id: "bridge", external_room_id: "room"},
               "hello"
             )

    assert error.reason == :partition_unavailable
    assert error.category == :fatal
    assert {:error, :supervisor_unavailable} = Instance.start_instance(:internal, %{name: "not-accepted"})
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert {:ok, _} = Supervisor.restart_child(context.root, registry)
    assert_recovered(context)
    assert Instance.count_instances() == 0
  end

  test "desired specifications survive their worker restart and reject stale timers", context do
    {:ok, provider} = Instance.start_instance(:internal, %{name: "desired"})
    supervisor = Module.concat(Instance, :InstanceSupervisor)
    manager_name = Module.concat(supervisor, :DesiredWorkers)
    old_manager = Process.whereis(manager_name)
    registry = Module.concat(Instance, Registry.Instances)
    :ok = Supervisor.terminate_child(context.root, registry)
    DesiredWorkers.restore(supervisor)
    assert_eventually(fn -> :sys.get_state(manager_name).retry != nil end)
    retry = :sys.get_state(manager_name).retry
    DesiredWorkers.restore(supervisor)
    DesiredWorkers.restore(supervisor)
    send(manager_name, {:restore, make_ref()})
    send(manager_name, :unrelated)
    assert :sys.get_state(manager_name).retry == retry
    Process.exit(old_manager, :kill)

    assert_eventually(fn ->
      pid = Process.whereis(manager_name)
      is_pid(pid) and pid != old_manager
    end)

    assert {:ok, _} = Supervisor.restart_child(context.root, registry)
    assert_recovered(context)
    assert_eventually(fn -> is_pid(InstanceServer.whereis(Instance, provider.id)) end, timeout: 2_000)
    DesiredWorkers.restore(supervisor)
    assert :sys.get_state(manager_name).supervisor == supervisor
    assert Instance.count_instances() == 1
  end

  test "recovery waits for a stale instance tree outside its supervisor", context do
    {:ok, provider} = Instance.start_instance(:internal, %{name: "stale"})
    supervisor = Module.concat(Instance, :InstanceSupervisor)
    [{_, tree, :supervisor, _}] = DynamicSupervisor.which_children(supervisor)
    # Stop the owned tree through the internal supervisor. The desired
    # specification remains, as it must for dependency recovery.
    assert :ok = DynamicSupervisor.terminate_child(supervisor, tree)
    assert {:ok, outsider} = InstanceSupervisor.start_instance_tree(Instance, provider)

    try do
      DesiredWorkers.restore(supervisor)
      manager = Module.concat(supervisor, :DesiredWorkers)
      assert_eventually(fn -> :sys.get_state(manager).retry != nil end)
      assert Process.alive?(outsider)
      assert Instance.count_instances() == 0
    after
      Supervisor.stop(outsider)
    end

    assert_eventually(fn -> Instance.count_instances() == 1 end, timeout: 2_000)
    assert is_pid(InstanceServer.whereis(Instance, provider.id))
    assert Process.whereis(context.runtime) == context.runtime_pid
  end

  test "duplicate start preserves the original desired configuration", context do
    {:ok, provider} = Instance.start_instance(:internal, %{id: "fixed", name: "original"})
    assert {:error, {:already_started, _}} = Instance.start_instance(:internal, %{id: "fixed", name: "replacement"})
    kill_registry()
    assert_recovered(context)
    assert_eventually(fn -> is_pid(InstanceServer.whereis(Instance, provider.id)) end, timeout: 2_000)
    assert {:ok, stored} = InstanceServer.get_instance(InstanceServer.whereis(Instance, provider.id))
    assert stored.name == "original"
  end

  test "standalone dynamic supervisors retain their existing start and stop behavior" do
    supervisor = Module.concat(__MODULE__, BareSupervisor)
    start_supervised!({DynamicSupervisor, name: supervisor, strategy: :one_for_one})
    assert {:ok, pid} = DesiredWorkers.start(__MODULE__, supervisor, :agent, {Agent, fn -> :value end})
    assert Agent.get(pid, & &1) == :value
    assert :ok = DesiredWorkers.stop(__MODULE__, supervisor, :agent, pid)
    refute Process.alive?(pid)
  end

  defp kill_registry do
    pid = Process.whereis(Module.concat(Instance, Registry.Instances))
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp assert_recovered(context) do
    assert_eventually(
      fn ->
        Enum.all?(0..63, fn index ->
          is_pid(Partition.whereis(Instance, index)) and is_pid(SessionManager.partition_pid(Instance, index))
        end)
      end,
      timeout: 3_000
    )

    assert Process.whereis(context.runtime) == context.runtime_pid
    assert {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    assert bus == context.bus
    assert Process.alive?(context.root)
  end
end
