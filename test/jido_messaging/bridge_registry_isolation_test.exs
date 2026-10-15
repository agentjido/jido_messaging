defmodule Jido.Messaging.BridgeRegistryIsolationTest do
  use ExUnit.Case, async: true
  import Jido.Messaging.TestHelpers
  alias Jido.Messaging.{BridgeConfig, BridgeServer, BridgeSupervisor, DesiredWorkers, RequestLedger, Runtime}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
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
    def listener_child_specs(_id, _opts), do: {:ok, [{Agent, fn -> :listener end}]}
  end

  defmodule FailingAdapter do
    use Jido.Chat.Adapter
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
    @impl true
    def listener_child_specs(_id, _opts), do: {:error, :listener_failed}
  end

  setup do
    root = start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    %{root: root, runtime: runtime, runtime_pid: Process.whereis(runtime), bus: bus}
  end

  test "registry loss restores configured bridges and listeners without restarting other groups", context do
    bridges = for id <- ~w(one two three four), do: configured_bridge(id)
    {:ok, _} = Instance.put_bridge_config(%{id: "disabled", adapter_module: Adapter, enabled: false})
    :ok = BridgeSupervisor.reconcile(Instance)
    old = for config <- bridges, do: BridgeServer.whereis(Instance, config.id)
    listeners = for pid <- old, do: :sys.get_state(pid).listener_supervisor
    unrelated = unrelated_pids()
    table = Runtime.request_table(context.runtime)
    {:ok, claim} = RequestLedger.claim(table, :retained, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, {:original, 42})
    kill_registry()

    assert_eventually(
      fn ->
        Enum.all?(Enum.zip(bridges, old), fn {config, previous} ->
          pid = BridgeServer.whereis(Instance, config.id)
          is_pid(pid) and pid != previous
        end)
      end,
      timeout: 3_000
    )

    assert length(BridgeSupervisor.list_bridges(Instance)) == 4

    for config <- bridges do
      assert {:ok, status} = BridgeServer.status(BridgeServer.whereis(Instance, config.id))
      assert status.revision == config.revision
      assert status.listener_count == 1
    end

    for pid <- listeners, do: refute(Process.alive?(pid))
    refute BridgeServer.whereis(Instance, "disabled")
    assert RequestLedger.claim(table, :retained, :payload, :authority) == {:cached, {:original, 42}}
    assert unrelated_pids() == unrelated
    assert_owners(context)
  end

  test "explicit stop removes the desired bridge but keeps explicit reconciliation available", context do
    keep = configured_bridge("keep")
    drop = configured_bridge("drop")
    :ok = BridgeSupervisor.reconcile(Instance)
    assert :ok = BridgeSupervisor.stop_bridge(Instance, drop.id)
    assert {:error, :not_found} = BridgeSupervisor.stop_bridge(Instance, drop.id)
    kill_registry()
    assert_eventually(fn -> is_pid(BridgeServer.whereis(Instance, keep.id)) end, timeout: 1_000)
    assert [%{bridge_id: "keep"}] = BridgeSupervisor.list_bridges(Instance)
    assert :ok = BridgeSupervisor.reconcile(Instance)
    assert is_pid(BridgeServer.whereis(Instance, drop.id))
    assert_owners(context)
  end

  test "recovery waits for an external registration without adopting or stopping it", context do
    config = BridgeConfig.new(%{id: "external", adapter_module: Adapter})
    {:ok, owned} = BridgeSupervisor.start_bridge(Instance, config)
    supervisor = Module.concat(Instance, :BridgeSupervisor)
    :ok = DynamicSupervisor.terminate_child(supervisor, owned)
    {:ok, external} = BridgeServer.start_link(instance_module: Instance, bridge_id: config.id, config: config)

    try do
      DesiredWorkers.restore(supervisor)

      assert_eventually(fn -> :sys.get_state(Module.concat(supervisor, :DesiredWorkers)).retry != nil end,
        timeout: 1_000
      )

      assert DynamicSupervisor.count_children(supervisor).active == 0
      assert Process.alive?(external)
    after
      GenServer.stop(external)
    end

    assert_eventually(fn -> DynamicSupervisor.count_children(supervisor).active == 1 end, timeout: 1_000)
    assert_owners(context)
  end

  test "failed startup is not retained and a duplicate start keeps the original config", context do
    bad = BridgeConfig.new(%{id: "bad", adapter_module: FailingAdapter})

    assert {:error, %{reason: :listener_failed, type: :adapter_callback_failure}} =
             BridgeSupervisor.start_bridge(Instance, bad)

    config = BridgeConfig.new(%{id: "good", adapter_module: Adapter, revision: 7})
    assert {:ok, old} = BridgeSupervisor.start_bridge(Instance, config)
    assert {:error, {:already_started, ^old}} = BridgeSupervisor.start_bridge(Instance, %{config | revision: 8})
    kill_registry()
    assert_eventually(fn -> is_pid(BridgeServer.whereis(Instance, config.id)) end, timeout: 1_000)
    assert [%{bridge_id: "good", revision: 7}] = BridgeSupervisor.list_bridges(Instance)
    refute BridgeServer.whereis(Instance, bad.id)
    assert_owners(context)
  end

  test "unavailable Runtime delays recovery without dropping the desired bridge", context do
    config = BridgeConfig.new(%{id: "retry", adapter_module: Adapter})
    {:ok, owned} = BridgeSupervisor.start_bridge(Instance, config)
    supervisor = Module.concat(Instance, :BridgeSupervisor)
    :ok = DynamicSupervisor.terminate_child(supervisor, owned)
    true = Process.unregister(context.runtime)

    try do
      DesiredWorkers.restore(supervisor)

      assert_eventually(fn -> :sys.get_state(Module.concat(supervisor, :DesiredWorkers)).retry != nil end,
        timeout: 1_000
      )

      assert BridgeServer.whereis(Instance, config.id) == nil
    after
      true = Process.register(context.runtime_pid, context.runtime)
    end

    assert_eventually(fn -> is_pid(BridgeServer.whereis(Instance, config.id)) end, timeout: 1_000)
    assert_owners(context)
  end

  test "group downtime returns existing empty and unavailable results", context do
    config = configured_bridge("down")
    :ok = BridgeSupervisor.reconcile(Instance)
    registry = Module.concat(Instance, Registry.Bridges)
    :ok = Supervisor.terminate_child(context.root, registry)
    assert BridgeServer.whereis(Instance, config.id) == nil
    assert BridgeSupervisor.list_bridges(Instance) == []
    assert :ok = BridgeServer.mark_ingress(Instance, config.id)
    assert :ok = BridgeServer.mark_outbound(Instance, config.id)
    assert :ok = BridgeServer.mark_error(Instance, config.id, :unavailable)
    assert {:error, :supervisor_unavailable} = BridgeSupervisor.start_bridge(Instance, config)

    assert {:error, {:reconcile_bridge_failed, "down", {:start_failed, :supervisor_unavailable}}} =
             BridgeSupervisor.reconcile(Instance)

    assert {:ok, _} = Supervisor.restart_child(context.root, registry)
    assert_eventually(fn -> is_pid(BridgeServer.whereis(Instance, config.id)) end, timeout: 1_000)
    assert_owners(context)
  end

  defp configured_bridge(id) do
    {:ok, config} = Instance.put_bridge_config(%{id: id, adapter_module: Adapter, enabled: true})
    config
  end

  defp kill_registry do
    pid = Process.whereis(Module.concat(Instance, Registry.Bridges))
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp unrelated_pids do
    for suffix <- [
          Registry.Rooms,
          Registry.Agents,
          Registry.Instances,
          :RoomSupervisor,
          :AgentSupervisor,
          :OutboundGatewaySupervisor,
          :DeadLetter,
          :ConfigStore,
          :Deduper
        ],
        do: Process.whereis(Module.concat(Instance, suffix))
  end

  defp assert_owners(context) do
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert Jido.Signal.Bus.whereis(Instance.signal_bus_name()) == {:ok, context.bus}
    assert Process.alive?(context.root)
  end
end
