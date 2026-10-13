defmodule Jido.Messaging.IngressSubscriptionStoreOutcomeTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{BridgeConfig, ConfigStore, IngressSubscription, Persistence.ETS, Runtime}

  defmodule Store do
    def init(opts), do: ETS.init(opts)
    defdelegate list_bridge_configs(state, opts), to: ETS
    defdelegate list_room_bindings(state, room), to: ETS
    defdelegate save_bridge_config(state, record), to: ETS

    def get_bridge_config(state, id), do: call(:read_bridge, fn -> ETS.get_bridge_config(state, id) end)

    def save_ingress_subscription(state, record),
      do: call(:save, fn -> ETS.save_ingress_subscription(state, record) end)

    def list_ingress_subscriptions(state, bridge, opts),
      do: call(:list, fn -> ETS.list_ingress_subscriptions(state, bridge, opts) end)

    def delete_ingress_subscription(state, bridge, id),
      do: call(:delete, fn -> ETS.delete_ingress_subscription(state, bridge, id) end)

    defp call(operation, fun) do
      control =
        Agent.get_and_update(__MODULE__.Control, fn state ->
          n = Map.get(state.attempts, operation, 0) + 1
          {Map.get(state.modes, operation, :pass), %{state | attempts: Map.put(state.attempts, operation, n)}}
        end)

      case control do
        :pass ->
          fun.()

        {:after_write, mode} ->
          result = fun.()
          Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1})
          fail(mode, result)

        {:on_attempt, attempt, mode} ->
          if Agent.get(__MODULE__.Control, & &1.attempts[operation]) == attempt, do: fail(mode, nil), else: fun.()

        mode ->
          fail(mode, nil)
      end
    end

    defp fail(:error, _), do: {:error, :store_unavailable}
    defp fail(:raise, _), do: raise("private store detail")
    defp fail(:throw, _), do: throw(:private_store_detail)
    defp fail(:exit, _), do: exit(:private_store_detail)
    defp fail(:invalid, _), do: :invalid
    defp fail(:foreign, {:ok, record}), do: {:ok, %{record | bridge_id: "foreign"}}
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :subscription_outcome
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])

    def ensure_ingress_subscription(bridge, _opts), do: response(:ensure, bridge)
    def list_ingress_subscriptions(bridge, _opts), do: response(:list, bridge)
    def delete_ingress_subscription(bridge, id, _opts), do: response(:delete, {bridge, id})

    defp response(operation, scope) do
      send(self(), {:provider_call, operation, scope})
      {:ok, Process.get(:subscription_response)}
    end
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{modes: %{}, attempts: %{}, writes: 0} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)
    config = BridgeConfig.new(%{id: "owned", adapter_module: Adapter, revision: 1})
    {:ok, ^config} = ETS.save_bridge_config(state, config)
    owned = record("owned", "existing")
    foreign = record("foreign", "existing")
    {:ok, ^owned} = ETS.save_ingress_subscription(state, owned)
    {:ok, ^foreign} = ETS.save_ingress_subscription(state, foreign)
    reset()
    {:ok, runtime: runtime, state: state, owned: owned, foreign: foreign}
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "stored subscription list #{mode} returns a defined failure and keeps ConfigStore alive", context do
      set_mode(:list, unquote(mode))
      expected = error(unquote(mode))
      assert {:error, ^expected} = ConfigStore.list_ingress_subscriptions(Instance, "owned")
      assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))
      assert_records(context, [context.owned])
    end

    test "delete #{mode} after-write failure retains the completed local deletion", context do
      Process.put(:subscription_response, %{subscription_id: "existing", status: :deleted})
      set_mode(:delete, {:after_write, unquote(mode)})
      expected = error(unquote(mode))
      assert {:error, ^expected} = Instance.delete_ingress_subscription("owned", "existing")
      assert_received {:provider_call, :delete, {"owned", "existing"}}
      assert Agent.get(Store.Control, & &1.writes) == 1
      assert_records(context, [])
      assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))
    end

    test "bridge read #{mode} fails before every provider operation", context do
      set_mode(:read_bridge, unquote(mode))
      expected = error(unquote(mode))

      for call <- [
            fn -> Instance.ensure_ingress_subscription("owned") end,
            fn -> Instance.list_ingress_subscriptions("owned") end,
            fn -> Instance.delete_ingress_subscription("owned", "existing") end
          ] do
        assert {:error, ^expected} = call.()
        assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))
        refute_received {:provider_call, _, _}
        assert_records(context, [context.owned])
      end
    end

    test "list save #{mode} returns failure and retains only earlier confirmed records", context do
      Process.put(:subscription_response, [
        %{subscription_id: "first"},
        %{subscription_id: "second"},
        %{subscription_id: "third"}
      ])

      set_mode(:save, {:on_attempt, 2, unquote(mode)})
      expected = error(unquote(mode))
      assert {:error, ^expected} = Instance.list_ingress_subscriptions("owned")
      assert_received {:provider_call, :list, "owned"}
      refute_received {:provider_call, _, _}
      assert Agent.get(Store.Control, & &1.attempts[:save]) == 2
      assert {:ok, stored} = ETS.list_ingress_subscriptions(context.state, "owned", [])
      assert Enum.sort(Enum.map(stored, & &1.subscription_id)) == ["existing", "first"]
      assert_foreign(context)
    end

    test "delete store #{mode} does not report local cleanup success", context do
      Process.put(:subscription_response, %{subscription_id: "existing", status: :deleted})
      set_mode(:delete, unquote(mode))
      expected = error(unquote(mode))
      assert {:error, ^expected} = Instance.delete_ingress_subscription("owned", "existing")
      assert_received {:provider_call, :delete, {"owned", "existing"}}
      assert_records(context, [context.owned])
      assert Process.alive?(Process.whereis(ConfigStore.name(Instance)))
    end

    test "ensure #{mode} after-write failure preserves one complete confirmed record", context do
      Process.put(:subscription_response, %{subscription_id: "new", metadata: %{complete: "all data"}})
      set_mode(:save, {:after_write, unquote(mode)})
      expected = error(unquote(mode))
      assert {:error, ^expected} = Instance.ensure_ingress_subscription("owned")
      assert_received {:provider_call, :ensure, "owned"}
      assert Agent.get(Store.Control, & &1.writes) == 1
      assert {:ok, stored} = ETS.list_ingress_subscriptions(context.state, "owned", [])
      assert Enum.sort(Enum.map(stored, & &1.subscription_id)) == ["existing", "new"]
      assert Enum.find(stored, &(&1.subscription_id == "new")).metadata == %{complete: "all data"}
      assert_foreign(context)
    end
  end

  test "malformed delete response cannot remove the local subscription", context do
    Process.put(:subscription_response, "invalid")
    assert {:error, :invalid_subscription_result} = Instance.delete_ingress_subscription("owned", "existing")
    assert_received {:provider_call, :delete, {"owned", "existing"}}
    assert_records(context, [context.owned])
    assert Agent.get(Store.Control, &Map.get(&1.attempts, :delete, 0)) == 0
  end

  test "delete acknowledgement keeps the requested identity when the provider supplies another ID", context do
    Process.put(:subscription_response, %{subscription_id: "foreign-id", status: :deleted})
    assert {:ok, deleted} = Instance.delete_ingress_subscription("owned", "existing")
    assert deleted.subscription_id == "existing"
    assert deleted.bridge_id == "owned"
    assert_records(context, [])
  end

  test "foreign save result cannot be reported as a successful owned record", context do
    Process.put(:subscription_response, %{subscription_id: "new"})
    set_mode(:save, {:after_write, :foreign})
    assert {:error, :persistence_failed} = Instance.ensure_ingress_subscription("owned")
    assert_received {:provider_call, :ensure, "owned"}
    assert {:ok, stored} = ETS.list_ingress_subscriptions(context.state, "owned", [])
    assert Enum.sort(Enum.map(stored, & &1.subscription_id)) == ["existing", "new"]
    assert_foreign(context)
  end

  defp reset, do: Agent.update(Store.Control, &%{&1 | modes: %{}, attempts: %{}, writes: 0})
  defp set_mode(operation, mode), do: Agent.update(Store.Control, &%{&1 | modes: Map.put(&1.modes, operation, mode)})
  defp error(:error), do: :store_unavailable
  defp error(_), do: :persistence_failed

  defp record(bridge, id),
    do:
      IngressSubscription.new(%{
        bridge_id: bridge,
        adapter_name: :subscription_outcome,
        subscription_id: id,
        metadata: %{complete: bridge}
      })

  defp assert_records(context, records) do
    assert {:ok, ^records} = ETS.list_ingress_subscriptions(context.state, "owned", [])
    assert_foreign(context)
  end

  defp assert_foreign(context) do
    assert {:ok, [foreign]} = ETS.list_ingress_subscriptions(context.state, "foreign", [])
    assert foreign == context.foreign
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
  end
end
