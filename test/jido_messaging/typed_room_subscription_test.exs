defmodule Jido.Messaging.TypedRoomSubscriptionTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{Events, RoomServer, RoomSupervisor}
  alias Jido.Messaging.Signal.Identity

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    room = Room.new(%{type: :group, name: "Room"})
    {:ok, server} = RoomSupervisor.start_room(Instance, room)
    selector = [source: Events.source(Instance), subject: Identity.room_subject(room.id)]
    {:ok, subscription} = Instance.subscribe_signals("jido.messaging.room.**", selector: selector)
    {:ok, room: room, server: server, subscription: subscription}
  end

  test "retired wrappers and the alternate PubSub module are absent" do
    refute Code.ensure_loaded?(Jido.Messaging.PubSub)
    refute Code.ensure_loaded?(Jido.Messaging.CommandResult)

    for {name, arity} <- [
          subscribe: 1,
          unsubscribe: 1,
          post_message: 1,
          route_payload: 2,
          route_webhook: 2,
          dispatch_room_event: 2,
          participant_joined: 2,
          add_reaction: 3
        ] do
      refute function_exported?(Instance, name, arity)
    end
  end

  test "native unsubscribe stops observation", context do
    :ok = Instance.unsubscribe_signals(context.subscription)
    {:ok, signal} = Events.room_event(Instance, :room_created, context.room.id, %{name: "Room", kind: "group"})
    assert {:ok, ^signal} = Jido.Messaging.Dispatch.emit(Instance, signal)
    refute_receive {:signal, _}
  end

  test "source and subject selectors both apply", context do
    {:ok, other_room} = Events.room_event(Instance, :room_created, "other-room", %{name: "Other", kind: "group"})

    {:ok, other_source} =
      Events.room_event(OtherInstance, :room_created, context.room.id, %{name: "Other", kind: "group"})

    {:ok, selected} = Events.room_event(Instance, :room_created, context.room.id, %{name: "Room", kind: "group"})
    assert {:ok, _} = Jido.Signal.Bus.publish(Instance.signal_bus_name(), [other_room, other_source, selected])
    assert_receive {:signal, ^selected}
    refute_receive {:signal, _}
  end

  test "message changes emit one typed fact and no tuple mirror", context do
    message =
      Jido.Messaging.Message.new(%{
        room_id: context.room.id,
        sender_id: "participant",
        role: :user,
        content: [Jido.Chat.Content.Text.new("hello")]
      })

    assert :ok = RoomServer.add_message(context.server, message)
    assert_receive {:signal, fact}
    assert fact.type == "jido.messaging.room.message_added"
    assert fact.data["message_id"] == message.id
    assert fact.subject == Identity.room_subject(context.room.id)
    refute_receive {:message_added, _}
    refute_receive {:signal, _}
  end

  test "participant join emits one typed fact", context do
    participant = Participant.new(%{type: :human})
    assert :ok = RoomServer.add_participant(context.server, participant)
    assert_receive {:signal, fact}
    assert fact.type == "jido.messaging.room.participant_joined"
    assert fact.data["participant_id"] == participant.id
    refute_receive {:participant_joined, _}
    refute_receive {:signal, _}
  end

  test "participant leave emits one typed fact", context do
    participant = Participant.new(%{type: :human})
    assert :ok = RoomServer.add_participant(context.server, participant)
    assert_receive {:signal, %{type: "jido.messaging.room.participant_joined"}}
    assert :ok = RoomServer.remove_participant(context.server, participant.id)
    assert_receive {:signal, fact}
    assert fact.type == "jido.messaging.room.participant_left"
    assert fact.data["participant_id"] == participant.id
    refute_receive {:participant_left, _}
    refute_receive {:signal, _}
  end
end
