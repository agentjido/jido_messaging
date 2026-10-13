defmodule Jido.Messaging.BridgeInventoryOutcomeTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{
    BridgeConfig,
    BridgeRoomSpec,
    BridgeServer,
    BridgeSupervisor,
    ConfigStore,
    OutboundRouter,
    Persistence.ETS,
    Runtime,
    TopologyValidator
  }

  defmodule Store do
    def init(opts), do: ETS.init(opts)
    defdelegate get_bridge_config(state, id), to: ETS
    defdelegate list_room_bindings(state, room), to: ETS
    defdelegate get_routing_policy(state, room), to: ETS

    def list_bridge_configs(state, opts) do
      Agent.update(__MODULE__.Control, &%{&1 | calls: &1.calls + 1})

      case Agent.get(__MODULE__.Control, & &1.mode) do
        :pass -> ETS.list_bridge_configs(state, opts)
        :error -> {:error, :inventory_unavailable}
        :raise -> raise "private bridge inventory"
        :throw -> throw(:private_bridge_inventory)
        :exit -> exit(:private_bridge_inventory)
        :invalid -> :invalid
        :invalid_list -> {:ok, :invalid}
        {:result, result} -> {:ok, result}
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :bridge_inventory
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{mode: :pass, calls: 0} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)

    configs =
      for id <- ["owned", "other"] do
        config = BridgeConfig.new(%{id: id, adapter_module: Adapter, revision: 1, opts: %{complete: id}})
        {:ok, ^config} = ETS.save_bridge_config(state, config)
        config
      end

    :ok = BridgeSupervisor.reconcile(Instance)
    workers = Map.new(configs, &{&1.id, BridgeServer.whereis(Instance, &1.id)})
    assert Enum.all?(workers, fn {_id, pid} -> is_pid(pid) and Process.alive?(pid) end)
    {:ok, runtime: runtime, state: state, configs: Enum.sort_by(configs, & &1.id), workers: workers}
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_list] do
    test "inventory #{mode} fails without stopping or replacing running bridges", context do
      set_mode(unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = Instance.list_bridge_configs()
      assert {:error, ^expected} = BridgeSupervisor.reconcile(Instance)
      assert {:error, ^expected} = OutboundRouter.plan(Instance, "room")
      assert {:error, ^expected} = TopologyValidator.validate_bridge_room_spec(Instance, BridgeRoomSpec.new(%{}))
      assert {:error, ^expected} = Instance.create_bridge_room(%{room_id: "uncreated", room_name: "Complete Name"})
      assert :ets.info(context.state.rooms, :size) == 0
      assert_preserved(context)
      set_mode(:pass)
      assert :ok = BridgeSupervisor.reconcile(Instance)
      assert_preserved(context)
    end
  end

  test "whole malformed inventories reject before partial reconciliation", context do
    [first, second] = context.configs

    for invalid <- [
          nil,
          %{},
          %{first | id: nil},
          %{first | enabled: nil},
          %{first | revision: "1"},
          %{first | opts: self()},
          %{first | credentials: %{token: "private fixture"}}
        ] do
      set_mode({:result, [first, invalid]})
      assert {:error, :persistence_failed} = Instance.list_bridge_configs()
      assert {:error, :persistence_failed} = BridgeSupervisor.reconcile(Instance)
      assert_preserved(context)
    end

    set_mode({:result, [first, %{second | id: first.id}]})
    assert {:error, :persistence_failed} = BridgeSupervisor.reconcile(Instance)
    assert_preserved(context)
  end

  test "successful inventories retain their list API, complete records and enabled filter", context do
    assert Instance.list_bridge_configs() == context.configs
    assert Instance.list_bridge_configs(enabled: true) == context.configs
    assert Instance.list_bridge_configs(enabled: false) == []
    assert_preserved(context)
  end

  test "a store that ignores the enabled filter cannot change the requested inventory", context do
    set_mode({:result, context.configs})
    assert {:error, :persistence_failed} = Instance.list_bridge_configs(enabled: false)
    assert_preserved(context)
  end

  test "a confirmed empty inventory stops only workers removed from the store", context do
    :ok = ETS.delete_bridge_config(context.state, "owned")
    assert :ok = BridgeSupervisor.reconcile(Instance)
    assert Process.alive?(context.workers["other"])
    assert BridgeServer.whereis(Instance, "other") == context.workers["other"]
    refute Process.alive?(context.workers["owned"])
  end

  defp set_mode(mode), do: Agent.update(Store.Control, &%{&1 | mode: mode})
  defp expected(:error), do: :inventory_unavailable
  defp expected(_), do: :persistence_failed

  defp assert_preserved(context) do
    assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))

    for {id, pid} <- context.workers do
      assert Process.alive?(pid)
      assert BridgeServer.whereis(Instance, id) == pid
      assert {:ok, status} = BridgeServer.status(pid)
      assert status.revision == 1
    end

    assert {:ok, configs} = ETS.list_bridge_configs(context.state, [])
    assert configs == context.configs
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert Instance.count_agents() == 0
  end
end
