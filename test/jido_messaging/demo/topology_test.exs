defmodule Jido.Messaging.Demo.TopologyTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.Demo.Topology

  defmodule TopologyTestMessaging do
    use Jido.Messaging, adapter: Jido.Messaging.Adapters.ETS
  end

  setup do
    start_supervised!({TopologyTestMessaging, []})
    :ok
  end

  test "loads topology YAML and resolves mode + bridge values" do
    path = Path.join(System.tmp_dir!(), "jido_messaging_topology_#{System.unique_integer([:positive])}.yaml")

    File.write!(
      path,
      """
      mode: bridge
      bridge:
        telegram_adapter: Elixir.Jido.Chat.Telegram.Adapter
        telegram_chat_id: 123456789
      """
    )

    assert {:ok, topology} = Topology.load(path)
    assert Topology.mode(topology) == :bridge
    assert Topology.bridge_value(topology, "telegram_chat_id") == 123_456_789
    assert Topology.adapter_module(topology, "telegram_adapter") == Jido.Chat.Telegram.Adapter
  end

  test "applies control-plane topology to runtime" do
    topology = %{
      "bridge_configs" => [
        %{
          "id" => "telegram-main",
          "adapter_module" => "Elixir.MyApp.FakeTelegramAdapter",
          "enabled" => true
        }
      ],
      "rooms" => [
        %{"id" => "demo:lobby", "type" => "group", "name" => "Demo Lobby"}
      ],
      "room_bindings" => [
        %{
          "room_id" => "demo:lobby",
          "channel" => "telegram",
          "bridge_id" => "telegram-main",
          "external_room_id" => "123456789",
          "direction" => "both",
          "enabled" => true
        }
      ],
      "routing_policies" => [
        %{
          "room_id" => "demo:lobby",
          "delivery_mode" => "best_effort",
          "failover_policy" => "next_available",
          "dedupe_scope" => "message_id",
          "fallback_order" => ["telegram-main"]
        }
      ]
    }

    assert {:ok, summary} = Topology.apply(TopologyTestMessaging, topology)
    assert summary.bridge_configs == 1
    assert summary.rooms == 1
    assert summary.room_bindings == 1
    assert summary.routing_policies == 1

    assert {:ok, _bridge} = TopologyTestMessaging.get_bridge_config("telegram-main")
    assert {:ok, room} = TopologyTestMessaging.get_room("demo:lobby")
    assert room.id == "demo:lobby"

    assert {:ok, bindings} = TopologyTestMessaging.list_room_bindings("demo:lobby")
    assert length(bindings) == 1

    assert {:ok, policy} = TopologyTestMessaging.get_routing_policy("demo:lobby")
    assert policy.room_id == "demo:lobby"
  end

  test "applying the same topology twice is idempotent for room bindings" do
    topology = %{
      "rooms" => [
        %{"id" => "demo:lobby", "type" => "group", "name" => "Demo Lobby"}
      ],
      "room_bindings" => [
        %{
          "room_id" => "demo:lobby",
          "channel" => "telegram",
          "bridge_id" => "telegram-main",
          "external_room_id" => "123456789",
          "direction" => "both",
          "enabled" => true
        }
      ]
    }

    assert {:ok, _summary} = Topology.apply(TopologyTestMessaging, topology)
    assert {:ok, _summary} = Topology.apply(TopologyTestMessaging, topology)

    assert {:ok, bindings} = TopologyTestMessaging.list_room_bindings("demo:lobby")
    assert length(bindings) == 1
  end
end
