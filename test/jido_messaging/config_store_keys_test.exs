defmodule Jido.Messaging.ConfigStoreKeysTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{ConfigStore, IngressSubscription, RoutingPolicy}

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :config_scope_test
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  defmodule Runtime do
    use Jido.Messaging
  end

  test "PID record calls retain disabled bridge state and subscription scope" do
    pid = Process.whereis(ConfigStore.name(Runtime))

    assert {:ok, config} =
             ConfigStore.put_bridge_config(pid, %{
               "id" => "owned-bridge",
               "adapter" => Adapter,
               "enabled" => false,
               "opts" => %{"mode" => "fixture"}
             })

    refute config.enabled
    assert config.opts == %{"mode" => "fixture"}
    assert {:ok, ^config} = ConfigStore.get_bridge_config(pid, config.id)
    assert [^config] = ConfigStore.list_bridge_configs(pid, enabled: false)
    assert [] = ConfigStore.list_bridge_configs(pid, enabled: true)

    for bridge <- ["owned-bridge", "foreign-bridge"] do
      subscription = IngressSubscription.new(%{bridge_id: bridge, adapter_name: Adapter, subscription_id: "same-id"})
      assert {:ok, ^subscription} = ConfigStore.save_ingress_subscription(pid, subscription)
    end

    assert {:ok, [owned]} = ConfigStore.list_ingress_subscriptions(pid, "owned-bridge")
    assert owned.bridge_id == "owned-bridge"
    assert :ok = ConfigStore.delete_ingress_subscription(pid, "owned-bridge", "same-id")
    assert {:ok, []} = ConfigStore.list_ingress_subscriptions(pid, "owned-bridge")
    assert {:ok, [foreign]} = ConfigStore.list_ingress_subscriptions(pid, "foreign-bridge")
    assert foreign.bridge_id == "foreign-bridge"
    assert :ok = ConfigStore.delete_bridge_config(pid, config.id)
    assert {:error, :not_found} = ConfigStore.get_bridge_config(pid, config.id)
  end

  setup do
    start_supervised!(Runtime)
    :ok
  end

  test "routing policy accepts only fixed string-to-atom conversions" do
    for {key, values} <- [
          {:delivery_mode, [:best_effort, :primary, :broadcast]},
          {:failover_policy, [:none, :next_available, :broadcast]},
          {:dedupe_scope, [:message_id, :thread, :room]}
        ],
        value <- values do
      for input <- [value, Atom.to_string(value)] do
        policy = RoutingPolicy.new(%{key => input, :room_id => "enum-room"})
        assert Map.fetch!(policy, key) == value
      end
    end

    unknown = "jido_unknown_policy_#{System.unique_integer([:positive])}"
    policy = RoutingPolicy.new(%{room_id: "enum-room", delivery_mode: unknown})
    assert policy.delivery_mode == unknown
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "string routing fields retain the same revision and values as struct updates" do
    pid = Process.whereis(ConfigStore.name(Runtime))

    attrs = %{
      "delivery_mode" => "primary",
      "failover_policy" => "none",
      "dedupe_scope" => "thread",
      "fallback_order" => ["selected-bridge"],
      "metadata" => %{"owner" => "caller"},
      "revision" => 0
    }

    assert {:ok, policy} = ConfigStore.put_routing_policy(pid, "caller-room", attrs)
    assert policy.delivery_mode == :primary
    assert policy.failover_policy == :none
    assert policy.dedupe_scope == :thread
    assert policy.fallback_order == ["selected-bridge"]
    assert policy.metadata == %{"owner" => "caller"}
    assert policy.revision == 1
    assert {:ok, ^policy} = ConfigStore.get_routing_policy(pid, "caller-room")

    update = %{policy | failover_policy: :broadcast, delivery_mode: :broadcast}
    assert {:ok, next} = ConfigStore.put_routing_policy(pid, "caller-room", update)
    assert %RoutingPolicy{revision: 2, delivery_mode: :broadcast, failover_policy: :broadcast} = next
    assert next.inserted_at == policy.inserted_at
    assert next.fallback_order == policy.fallback_order
    assert {:error, {:revision_conflict, 1, 2}} = ConfigStore.put_routing_policy(pid, "caller-room", update)
    assert {:ok, ^next} = ConfigStore.get_routing_policy(pid, "caller-room")
    assert :ok = ConfigStore.delete_routing_policy(pid, "caller-room")
    assert {:error, :not_found} = ConfigStore.get_routing_policy(pid, "caller-room")
  end
end
