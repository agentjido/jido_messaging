defmodule Jido.Messaging.CreateBridgeRoomTest do
  use ExUnit.Case, async: false

  defmodule BridgeAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "msg-1"}}
  end

  defmodule BridgeRoomMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(BridgeRoomMessaging)
    :ok
  end

  test "create_bridge_room/2 is idempotent for room, bindings, and routing policy" do
    attrs = %{
      room_id: "demo:lobby",
      room_type: :group,
      room_name: "Demo Lobby",
      bridge_configs: [
        %{id: "bridge_tg", adapter_module: BridgeAdapter, enabled: true},
        %{id: "bridge_dc", adapter_module: BridgeAdapter, enabled: true}
      ],
      bindings: [
        %{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "1001", direction: :both},
        %{channel: :discord, bridge_id: "bridge_dc", external_room_id: "2002", direction: :both}
      ],
      routing_policy: %{delivery_mode: :best_effort, fallback_order: ["bridge_tg", "bridge_dc"]}
    }

    assert {:ok, room} = Jido.Messaging.create_bridge_room(BridgeRoomMessaging, attrs)
    assert room.id == "demo:lobby"

    assert {:ok, room2} = Jido.Messaging.create_bridge_room(BridgeRoomMessaging, attrs)
    assert room2.id == "demo:lobby"

    assert {:ok, bindings} = BridgeRoomMessaging.list_room_bindings("demo:lobby")
    assert length(bindings) == 2

    assert {:ok, policy} = BridgeRoomMessaging.get_routing_policy("demo:lobby")
    assert policy.delivery_mode == :best_effort
  end

  test "create_bridge_room/2 returns conflict when binding already belongs to another room" do
    attrs_a = %{
      room_id: "room:a",
      bridge_configs: [%{id: "bridge_tg", adapter_module: BridgeAdapter, enabled: true}],
      bindings: [%{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "shared-room"}]
    }

    attrs_b = %{
      room_id: "room:b",
      bindings: [%{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "shared-room"}]
    }

    assert {:ok, _room_a} = Jido.Messaging.create_bridge_room(BridgeRoomMessaging, attrs_a)

    assert {:error, {:binding_conflict, %{room_id: "room:b", existing_room_id: "room:a"}}} =
             Jido.Messaging.create_bridge_room(BridgeRoomMessaging, attrs_b)
  end

  test "create_bridge_room/2 does not atomize unknown bridge config string keys" do
    dynamic_key = "custom_key_" <> Integer.to_string(System.unique_integer([:positive]))
    atom_count_before = :erlang.system_info(:atom_count)

    attrs = %{
      room_id: "room:atom-safe",
      bridge_configs: [
        %{
          "id" => "bridge_tg_dynamic",
          "adapter_module" => BridgeAdapter,
          dynamic_key => "dynamic-value"
        }
      ],
      bindings: [
        %{channel: :telegram, bridge_id: "bridge_tg_dynamic", external_room_id: "3003", direction: :both}
      ]
    }

    assert {:ok, room} = Jido.Messaging.create_bridge_room(BridgeRoomMessaging, attrs)
    assert room.id == "room:atom-safe"

    atom_count_after = :erlang.system_info(:atom_count)
    assert atom_count_after == atom_count_before
    assert_raise ArgumentError, fn -> String.to_existing_atom(dynamic_key) end
  end
end
