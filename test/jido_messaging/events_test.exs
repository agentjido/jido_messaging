defmodule Jido.Messaging.EventsTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.CommandResult
  alias Jido.Messaging.TestMessaging

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  test "post_message persists and dispatches a message_added signal" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Signals"})
    {:ok, subscription_id} = TestMessaging.subscribe_signals("jido.messaging.room.message_added")

    assert {:ok, %CommandResult{record: message, signals: [signal]}} =
             TestMessaging.post_message(%{
               room_id: room.id,
               sender_id: "user:1",
               role: :user,
               content: [%{type: "text", text: "Hello from signals"}],
               status: :sent
             })

    assert message.content == [%{type: "text", text: "Hello from signals"}]
    assert signal.type == "jido.messaging.room.message_added"
    assert signal.subject == room.id
    assert signal.data["message_id"] == message.id
    assert signal.data["target"]["external_id"] == room.id
    assert signal.data["payload"]["text"] == "Hello from signals"

    assert_receive {:signal, received_signal}, 1_000
    assert received_signal.type == signal.type
    assert received_signal.data["message_id"] == message.id

    :ok = TestMessaging.unsubscribe_signals(subscription_id)
  end

  test "save_message remains a persistence primitive without signal side effects" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Quiet persistence"})
    {:ok, subscription_id} = TestMessaging.subscribe_signals("jido.messaging.room.message_added")

    assert {:ok, _message} =
             TestMessaging.save_message(%{
               room_id: room.id,
               sender_id: "user:1",
               role: :user,
               content: [%{type: "text", text: "No event"}],
               status: :sent
             })

    refute_receive {:signal, _signal}, 100

    :ok = TestMessaging.unsubscribe_signals(subscription_id)
  end

  test "event metadata is CloudEvents-friendly plain data" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Plain signals"})

    assert {:ok, %CommandResult{signals: [signal]}} =
             TestMessaging.post_message(
               %{
                 room_id: room.id,
                 sender_id: "user:1",
                 role: :user,
                 content: [%{type: "text", text: "Plain metadata"}],
                 status: :sent
               },
               channel_type: :campfire,
               instance_id: :demo_workspace,
               external_room_id: :general,
               payload_kind: :text,
               target_kind: :room
             )

    assert signal.data["platform"]["channel_type"] == "campfire"
    assert signal.data["platform"]["external_room_id"] == "general"
    assert signal.data["target"]["channel_type"] == "campfire"
    assert signal.data["target"]["instance_id"] == "demo_workspace"
    assert signal.data["target"]["external_id"] == "general"
    assert signal.data["payload"]["kind"] == "text"
  end

  test "event constructors normalize string option keys without creating atoms" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "String options"})

    assert {:ok, %CommandResult{signals: [signal]}} =
             TestMessaging.post_message(
               %{
                 room_id: room.id,
                 sender_id: "user:1",
                 role: :user,
                 content: [%{type: "text", text: "String-key options"}],
                 status: :sent
               },
               %{
                 "channel_type" => "campfire",
                 "instance_id" => "demo",
                 "external_room_id" => "general",
                 "target_kind" => "room"
               }
             )

    assert signal.data["platform"]["channel_type"] == "campfire"
    assert signal.data["platform"]["external_room_id"] == "general"
    assert signal.data["target"]["instance_id"] == "demo"
    assert signal.data["target"]["external_id"] == "general"

    assert Jido.Messaging.Events.telemetry_event_for("jido.messaging.participant.presence_changed") ==
             [:jido_messaging, :participant, :presence_changed]

    assert Jido.Messaging.Events.telemetry_event_for("third.party.untrusted_event") ==
             [:jido_messaging, :signal, :custom]
  end

  test "reaction commands persist and dispatch reaction signals" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Reactions"})

    {:ok, %CommandResult{record: message}} =
      TestMessaging.post_message(%{
        room_id: room.id,
        sender_id: "user:1",
        role: :user,
        content: [%{type: "text", text: "React here"}],
        status: :sent
      })

    {:ok, subscription_id} = TestMessaging.subscribe_signals("jido.messaging.message.**")

    assert {:ok, %CommandResult{record: reacted, signals: [added_signal]}} =
             TestMessaging.add_reaction(message.id, "user:2", "+1")

    assert reacted.reactions["+1"] == ["user:2"]
    assert added_signal.type == "jido.messaging.message.reaction_added"
    assert added_signal.data["participant_id"] == "user:2"
    assert added_signal.data["reaction"] == "+1"

    assert_receive {:signal, received_added}, 1_000
    assert received_added.type == "jido.messaging.message.reaction_added"

    assert {:ok, %CommandResult{record: unchanged_reacted, signals: []}} =
             TestMessaging.add_reaction(message.id, "user:2", "+1")

    assert unchanged_reacted.reactions["+1"] == ["user:2"]
    refute_receive {:signal, _signal}, 100

    assert {:ok, %CommandResult{record: unreacted, signals: [removed_signal]}} =
             TestMessaging.remove_reaction(message.id, "user:2", "+1")

    assert unreacted.reactions == %{}
    assert removed_signal.type == "jido.messaging.message.reaction_removed"

    assert_receive {:signal, received_removed}, 1_000
    assert received_removed.type == "jido.messaging.message.reaction_removed"

    assert {:ok, %CommandResult{record: unchanged, signals: []}} =
             TestMessaging.remove_reaction(message.id, "user:2", "+1")

    assert unchanged.reactions == %{}
    refute_receive {:signal, _signal}, 100

    :ok = TestMessaging.unsubscribe_signals(subscription_id)
  end

  test "participant activity helpers dispatch canonical signals" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Presence"})
    {:ok, subscription_id} = TestMessaging.subscribe_signals("jido.messaging.**")

    assert {:ok, joined} =
             TestMessaging.participant_joined(room.id, "user:1",
               session_id: "session-1",
               presence: :online,
               source: "test"
             )

    assert joined.type == "jido.messaging.room.participant_joined"
    assert joined.subject == room.id
    assert joined.data["participant_id"] == "user:1"
    assert joined.data["presence"] == :online
    assert joined.data["source"] == "test"

    assert_receive {:signal, received_joined}, 1_000
    assert received_joined.type == joined.type

    assert {:ok, changed} =
             TestMessaging.participant_presence_changed(room.id, "user:1", :offline, :online,
               session_id: "session-1",
               source: "test"
             )

    assert changed.type == "jido.messaging.participant.presence_changed"
    assert changed.data["from"] == :offline
    assert changed.data["to"] == :online

    assert {:ok, typing} =
             TestMessaging.participant_typing(room.id, "user:1", true,
               thread_id: "thread:1",
               source: "test"
             )

    assert typing.type == "jido.messaging.participant.typing"
    assert typing.data["thread_id"] == "thread:1"
    assert typing.data["is_typing"] == true

    assert {:ok, left} =
             TestMessaging.participant_left(room.id, "user:1",
               session_id: "session-1",
               reason: :expired,
               source: "test"
             )

    assert left.type == "jido.messaging.room.participant_left"
    assert left.data["reason"] == :expired

    :ok = TestMessaging.unsubscribe_signals(subscription_id)
  end
end
