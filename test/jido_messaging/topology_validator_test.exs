defmodule Jido.Messaging.TopologyValidatorTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{BridgeRoomSpec, TopologyValidator}

  defmodule DummyAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:ok, %{message_id: "m1"}}
  end

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  test "returns invalid_topology for duplicate binding keys" do
    spec =
      BridgeRoomSpec.new(%{
        bridge_configs: [%{id: "bridge_tg", adapter_module: DummyAdapter}],
        bindings: [
          %{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "chat_1"},
          %{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "chat_1"}
        ]
      })

    assert {:error, {:invalid_topology, errors}} =
             TopologyValidator.validate_bridge_room_spec(TestMessaging, spec)

    assert Enum.any?(errors, &(&1.code == :duplicate_binding))
  end

  test "returns invalid_topology when fallback order references unknown bridge ids" do
    spec =
      BridgeRoomSpec.new(%{
        bridge_configs: [%{id: "bridge_tg", adapter_module: DummyAdapter}],
        bindings: [%{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "chat_1"}],
        routing_policy: %{fallback_order: ["bridge_tg", "missing_bridge"]}
      })

    assert {:error, {:invalid_topology, errors}} =
             TopologyValidator.validate_bridge_room_spec(TestMessaging, spec)

    assert Enum.any?(errors, &(&1.code == :unknown_routing_bridge_id))
  end

  test "accepts valid bridge topology" do
    spec =
      BridgeRoomSpec.new(%{
        bridge_configs: [%{id: "bridge_tg", adapter_module: DummyAdapter}],
        bindings: [%{channel: :telegram, bridge_id: "bridge_tg", external_room_id: "chat_1"}],
        routing_policy: %{fallback_order: ["bridge_tg"]}
      })

    assert :ok = TopologyValidator.validate_bridge_room_spec(TestMessaging, spec)
  end
end
