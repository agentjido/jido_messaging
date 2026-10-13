defmodule Jido.Messaging.Demo.TopologyTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.Demo.Topology

  defmodule TopologyTestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!({TopologyTestMessaging, []})
    :ok
  end

  test "a topology cannot report another room's provider binding as its requested binding" do
    {:ok, _} = TopologyTestMessaging.create_room(%{id: "owner", type: :group})
    {:ok, _} = TopologyTestMessaging.create_room(%{id: "requested", type: :group})
    {:ok, existing} = TopologyTestMessaging.create_room_binding("owner", :telegram, "bridge", "peer")

    topology = %{
      "room_bindings" => [
        %{"room_id" => "requested", "channel" => "telegram", "bridge_id" => "bridge", "external_room_id" => "peer"}
      ]
    }

    assert {:error, {:room_binding_scope_conflict, "owner", "requested", _}} =
             Topology.apply(TopologyTestMessaging, topology)

    assert {:ok, [^existing]} = TopologyTestMessaging.list_room_bindings("owner")
    assert {:ok, []} = TopologyTestMessaging.list_room_bindings("requested")
  end

  for section <- ~w(bridge_rooms bridge_configs rooms room_bindings routing_policies) do
    test "malformed #{section} input fails before any topology record is stored" do
      topology = Map.put(%{"rooms" => [%{"id" => "must-not-exist", "type" => "group"}]}, unquote(section), :invalid)
      assert {:error, {:invalid_topology_section, unquote(section)}} = Topology.apply(TopologyTestMessaging, topology)
      assert {:ok, []} = TopologyTestMessaging.list_rooms()
      assert [] = TopologyTestMessaging.list_bridge_configs()
    end
  end

  test "atom and string topology keys select the same canonical sections" do
    topology = %{rooms: [%{id: "atom-room", type: :direct, name: "Atom"}]}
    assert {:ok, %{rooms: 1}} = Topology.apply(TopologyTestMessaging, topology)
    assert {:ok, room} = TopologyTestMessaging.get_room("atom-room")
    assert room.type == :direct
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

  test "loads topology YAML and resolves env placeholders" do
    previous_chat = System.get_env("TOPOLOGY_TEST_CHAT_ID")
    previous_bridge = System.get_env("TOPOLOGY_TEST_BRIDGE_ID")

    on_exit(fn ->
      if is_nil(previous_chat) do
        System.delete_env("TOPOLOGY_TEST_CHAT_ID")
      else
        System.put_env("TOPOLOGY_TEST_CHAT_ID", previous_chat)
      end

      if is_nil(previous_bridge) do
        System.delete_env("TOPOLOGY_TEST_BRIDGE_ID")
      else
        System.put_env("TOPOLOGY_TEST_BRIDGE_ID", previous_bridge)
      end
    end)

    System.put_env("TOPOLOGY_TEST_CHAT_ID", "424242")
    System.put_env("TOPOLOGY_TEST_BRIDGE_ID", "telegram-main")

    path = Path.join(System.tmp_dir!(), "jido_messaging_topology_env_#{System.unique_integer([:positive])}.yaml")

    File.write!(
      path,
      """
      mode: bridge
      bridge:
        telegram_chat_id: "${TOPOLOGY_TEST_CHAT_ID}"
      room_bindings:
        - room_id: demo:lobby
          channel: telegram
          bridge_id: "${TOPOLOGY_TEST_BRIDGE_ID}"
          external_room_id: "${TOPOLOGY_TEST_CHAT_ID}"
      """
    )

    assert {:ok, topology} = Topology.load(path)
    assert Topology.bridge_value(topology, "telegram_chat_id") == "424242"

    assert topology["room_bindings"] == [
             %{
               "room_id" => "demo:lobby",
               "channel" => "telegram",
               "bridge_id" => "telegram-main",
               "external_room_id" => "424242"
             }
           ]
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

  test "applies bridge_rooms topology via create_bridge_room helper" do
    topology = %{
      "bridge_rooms" => [
        %{
          "room_id" => "demo:bridge-room",
          "room_type" => "group",
          "room_name" => "Bridge Room",
          "bridge_configs" => [
            %{
              "id" => "bridge-room-tg",
              "adapter_module" => "Elixir.MyApp.FakeTelegramAdapter",
              "enabled" => true
            }
          ],
          "bindings" => [
            %{
              "channel" => "telegram",
              "bridge_id" => "bridge-room-tg",
              "external_room_id" => "123456789",
              "direction" => "both",
              "enabled" => true
            }
          ],
          "routing_policy" => %{
            "delivery_mode" => "best_effort",
            "fallback_order" => ["bridge-room-tg"]
          }
        }
      ]
    }

    assert {:ok, summary} = Topology.apply(TopologyTestMessaging, topology)
    assert summary.bridge_rooms == 1

    assert {:ok, room} = TopologyTestMessaging.get_room("demo:bridge-room")
    assert room.name == "Bridge Room"

    assert {:ok, bindings} = TopologyTestMessaging.list_room_bindings("demo:bridge-room")
    assert length(bindings) == 1
    assert hd(bindings).direction == :both
    assert hd(bindings).enabled == true
  end
end
