defmodule Jido.Messaging.DemoHeartbeatTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.Demo.HeartbeatSensor
  alias Jido.Messaging.TestMessaging

  test "one explicit tick stores one heartbeat and advances the count once" do
    start_supervised!(TestMessaging)
    assert {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Heartbeat"})

    pid =
      start_supervised!(
        {HeartbeatSensor,
         config: %{interval: 60_000, room_id: room.id, instance_module: TestMessaging}, initial_delay: 60_000}
      )

    assert :sys.get_state(pid).tick_count == 0
    send(pid, :tick)
    assert :sys.get_state(pid).tick_count == 1
    assert {:ok, [message]} = TestMessaging.list_messages(room.id)
    assert message.metadata.heartbeat
    assert message.metadata.tick_count == 1
    assert message.sender_id == "chat_agent"
  end

  test "invalid timer configuration fails before a process starts" do
    assert {:error, {:invalid_config, _}} =
             HeartbeatSensor.start_link(config: %{interval: 0, room_id: "room", instance_module: TestMessaging})
  end
end
