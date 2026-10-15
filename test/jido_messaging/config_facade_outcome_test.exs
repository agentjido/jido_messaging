defmodule Jido.Messaging.ConfigFacadeOutcomeTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{BridgeConfig, ConfigStore, OutboundRouter, Persistence.ETS, RoutingPolicy, Runtime}

  defmodule Store do
    def init(opts), do: ETS.init(opts)
    defdelegate list_bridge_configs(state, opts), to: ETS
    defdelegate get_bridge_config(state, id), to: ETS
    defdelegate list_room_bindings(state, room), to: ETS
    def get_routing_policy(state, id), do: call(:get, fn -> ETS.get_routing_policy(state, id) end)
    def delete_routing_policy(state, id), do: call(:delete_policy, fn -> ETS.delete_routing_policy(state, id) end)
    def delete_bridge_config(state, id), do: call(:delete_bridge, fn -> ETS.delete_bridge_config(state, id) end)

    defp call(operation, fun) do
      mode = Agent.get(__MODULE__.Control, &Map.get(&1.modes, operation, :pass))

      case mode do
        :pass ->
          fun.()

        {:after_write, failure} ->
          :ok = fun.()
          Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1})
          fail(failure)

        :foreign ->
          {:ok, policy} = fun.()
          {:ok, %{policy | id: "foreign", room_id: "foreign"}}

        :foreign_room ->
          {:ok, policy} = fun.()
          {:ok, %{policy | room_id: "foreign"}}

        failure ->
          fail(failure)
      end
    end

    defp fail(:error), do: {:error, :config_unavailable}
    defp fail(:raise), do: raise("private config callback")
    defp fail(:throw), do: throw(:private_config_callback)
    defp fail(:exit), do: exit(:private_config_callback)
    defp fail(:invalid), do: :invalid
    defp fail(:invalid_record), do: {:ok, %{id: "owned-room"}}
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :config_facade
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
      start: {Agent, :start_link, [fn -> %{modes: %{}, writes: 0} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)

    policies =
      for room <- ["owned-room", "foreign-room"] do
        policy = RoutingPolicy.new(%{room_id: room, revision: 1, metadata: %{complete: room}})
        {:ok, ^policy} = ETS.save_routing_policy(state, policy)
        policy
      end

    bridges =
      for id <- ["owned-bridge", "foreign-bridge"] do
        config = BridgeConfig.new(%{id: id, adapter_module: Adapter, enabled: false, revision: 1})
        {:ok, ^config} = ETS.save_bridge_config(state, config)
        config
      end

    {:ok, runtime: runtime, state: state, policies: policies, bridges: bridges}
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid, :invalid_record, :foreign, :foreign_room] do
    test "routing read #{mode} has no record effect and no default route", context do
      set_mode(:get, unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = ConfigStore.get_routing_policy(Instance, "owned-room")
      assert {:error, ^expected} = OutboundRouter.plan(Instance, "owned-room")
      assert_alive(context)
      assert {:ok, policy} = ETS.get_routing_policy(context.state, "owned-room")
      assert policy == hd(context.policies)
    end
  end

  for {operation, id} <- [delete_policy: "owned-room", delete_bridge: "owned-bridge"],
      mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{operation} #{mode} keeps the owned and foreign records", context do
      set_mode(unquote(operation), unquote(mode))
      expected = expected(unquote(mode))
      assert {:error, ^expected} = delete(unquote(operation), unquote(id))
      assert_alive(context)
      assert_owned(context, unquote(operation), true)
      assert Agent.get(Store.Control, & &1.writes) == 0
    end

    test "#{operation} #{mode} after-delete failure keeps only the confirmed deletion", context do
      set_mode(unquote(operation), {:after_write, unquote(mode)})
      expected = expected(unquote(mode))
      assert {:error, ^expected} = delete(unquote(operation), unquote(id))
      assert_alive(context)
      assert_owned(context, unquote(operation), false)
      assert Agent.get(Store.Control, & &1.writes) == 1
    end
  end

  defp delete(:delete_policy, id), do: ConfigStore.delete_routing_policy(Instance, id)
  defp delete(:delete_bridge, id), do: ConfigStore.delete_bridge_config(Instance, id)
  defp set_mode(operation, mode), do: Agent.update(Store.Control, &%{&1 | modes: Map.put(&1.modes, operation, mode)})
  defp expected(:error), do: :config_unavailable
  defp expected(_), do: :persistence_failed

  defp assert_alive(context) do
    assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))
    assert Jido.Messaging.TestHelpers.runtime_entry_count(context.runtime) == 0
    assert Instance.count_agents() == 0
  end

  defp assert_owned(context, :delete_policy, exists) do
    result = ETS.get_routing_policy(context.state, "owned-room")
    assert result == if(exists, do: {:ok, hd(context.policies)}, else: {:error, :not_found})
    assert {:ok, foreign} = ETS.get_routing_policy(context.state, "foreign-room")
    assert foreign == List.last(context.policies)
  end

  defp assert_owned(context, :delete_bridge, exists) do
    result = ETS.get_bridge_config(context.state, "owned-bridge")
    assert result == if(exists, do: {:ok, hd(context.bridges)}, else: {:error, :not_found})
    assert {:ok, foreign} = ETS.get_bridge_config(context.state, "foreign-bridge")
    assert foreign == List.last(context.bridges)
  end
end
