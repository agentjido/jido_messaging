defmodule Jido.Messaging.ConfigStoreTest do
  use ExUnit.Case, async: false

  defmodule TestAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule TestMessaging do
    use Jido.Messaging,
      adapter: Jido.Messaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "bridge configs" do
    test "put/get/list/delete bridge config" do
      {:ok, config} =
        TestMessaging.put_bridge_config(%{
          id: "bridge_tg_main",
          adapter_module: TestAdapter,
          enabled: true,
          opts: %{mode: :webhook}
        })

      assert config.id == "bridge_tg_main"
      assert config.revision == 1
      assert config.adapter_module == TestAdapter

      assert {:ok, fetched} = TestMessaging.get_bridge_config("bridge_tg_main")
      assert fetched.id == config.id
      assert fetched.capabilities == Jido.Chat.Adapter.capabilities(TestAdapter)

      assert [listed] = TestMessaging.list_bridge_configs()
      assert listed.id == "bridge_tg_main"

      assert [enabled] = TestMessaging.list_bridge_configs(enabled: true)
      assert enabled.id == "bridge_tg_main"
      assert [] = TestMessaging.list_bridge_configs(enabled: false)

      assert :ok = TestMessaging.delete_bridge_config("bridge_tg_main")
      assert {:error, :not_found} = TestMessaging.get_bridge_config("bridge_tg_main")
    end

    test "enforces optimistic revision checks" do
      {:ok, first} =
        TestMessaging.put_bridge_config(%{
          id: "bridge_rev",
          adapter_module: TestAdapter,
          enabled: true
        })

      {:ok, second} =
        TestMessaging.put_bridge_config(%{
          id: "bridge_rev",
          revision: first.revision,
          enabled: false
        })

      assert second.revision == first.revision + 1
      refute second.enabled

      assert {:error, {:revision_conflict, expected, actual}} =
               TestMessaging.put_bridge_config(%{
                 id: "bridge_rev",
                 revision: first.revision,
                 enabled: true
               })

      assert expected == first.revision
      assert actual == second.revision
    end
  end

  describe "routing policies" do
    test "put/get/delete routing policy with revisions" do
      {:ok, policy} =
        TestMessaging.put_routing_policy("room_123", %{
          delivery_mode: :primary,
          failover_policy: :next_available,
          fallback_order: ["bridge_tg_main"]
        })

      assert policy.room_id == "room_123"
      assert policy.revision == 1
      assert policy.delivery_mode == :primary

      assert {:ok, fetched} = TestMessaging.get_routing_policy("room_123")
      assert fetched.id == "room_123"

      {:ok, updated} =
        TestMessaging.put_routing_policy("room_123", %{
          revision: fetched.revision,
          failover_policy: :broadcast
        })

      assert updated.revision == fetched.revision + 1
      assert updated.failover_policy == :broadcast

      assert {:error, {:revision_conflict, _, _}} =
               TestMessaging.put_routing_policy("room_123", %{
                 revision: fetched.revision,
                 dedupe_scope: :thread
               })

      assert :ok = TestMessaging.delete_routing_policy("room_123")
      assert {:error, :not_found} = TestMessaging.get_routing_policy("room_123")
    end
  end
end
