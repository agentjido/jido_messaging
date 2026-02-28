defmodule Jido.Messaging.PubSubTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{LegacyMessage, Participant, Room}
  alias Jido.Messaging.{PubSub, RoomServer}

  @moduletag :pubsub

  setup do
    if PubSub.pubsub_available?() do
      start_supervised!({Phoenix.PubSub, name: Jido.Messaging.TestPubSub})
      start_supervised!(Jido.Messaging.TestMessagingWithPubSub)
      :ok
    else
      :ok
    end
  end

  describe "configured?/1" do
    test "returns false when PubSub is not configured" do
      refute PubSub.configured?(Jido.Messaging.TestMessaging)
    end

    @tag :skip_unless_pubsub
    test "returns true when PubSub is configured" do
      if PubSub.pubsub_available?() do
        assert PubSub.configured?(Jido.Messaging.TestMessagingWithPubSub)
      end
    end
  end

  describe "subscribe/2 and unsubscribe/2" do
    test "returns error when PubSub is not configured" do
      assert {:error, :not_configured} = PubSub.subscribe(Jido.Messaging.TestMessaging, "room_1")
      assert {:error, :not_configured} = PubSub.unsubscribe(Jido.Messaging.TestMessaging, "room_1")
    end

    @tag :skip_unless_pubsub
    test "subscribes and unsubscribes when PubSub is configured" do
      if PubSub.pubsub_available?() do
        room_id = "test_room_#{System.unique_integer([:positive])}"

        assert :ok = PubSub.subscribe(Jido.Messaging.TestMessagingWithPubSub, room_id)
        assert :ok = PubSub.unsubscribe(Jido.Messaging.TestMessagingWithPubSub, room_id)
      end
    end
  end

  describe "broadcast/3" do
    test "returns error when PubSub is not configured" do
      assert {:error, :not_configured} =
               PubSub.broadcast(Jido.Messaging.TestMessaging, "room_1", {:test, :event})
    end

    @tag :skip_unless_pubsub
    test "broadcasts events to subscribers when PubSub is configured" do
      if PubSub.pubsub_available?() do
        room_id = "test_room_#{System.unique_integer([:positive])}"

        :ok = PubSub.subscribe(Jido.Messaging.TestMessagingWithPubSub, room_id)
        :ok = PubSub.broadcast(Jido.Messaging.TestMessagingWithPubSub, room_id, {:test, :event})

        assert_receive {:test, :event}, 100
      end
    end
  end

  describe "topic/1" do
    test "generates correct topic pattern" do
      assert PubSub.topic("room_123") == "jido_messaging:rooms:room_123"
    end
  end

  describe "RoomServer broadcasts" do
    # Phase 6: These events now use Signal Bus instead of PubSub
    # See room_server_signals_test.exs for signal-based tests

    @tag :skip
    @tag :skip_unless_pubsub
    @tag :phase6_deprecated
    test "broadcasts message_added event when message is added" do
      if PubSub.pubsub_available?() do
        room = Room.new(%{type: :direct, name: "Test Room"})
        {:ok, _pid} = RoomServer.start_link(room: room, instance_module: Jido.Messaging.TestMessagingWithPubSub)
        server = RoomServer.via_tuple(Jido.Messaging.TestMessagingWithPubSub, room.id)

        :ok = PubSub.subscribe(Jido.Messaging.TestMessagingWithPubSub, room.id)

        message =
          LegacyMessage.new(%{
            room_id: room.id,
            sender_id: "user_1",
            role: :user,
            content: [%{type: :text, text: "Hello"}]
          })

        :ok = RoomServer.add_message(server, message)

        assert_receive {:message_added, ^message}, 100
      end
    end

    @tag :skip
    @tag :skip_unless_pubsub
    @tag :phase6_deprecated
    test "broadcasts participant_joined event when participant is added" do
      if PubSub.pubsub_available?() do
        room = Room.new(%{type: :direct, name: "Test Room"})
        {:ok, _pid} = RoomServer.start_link(room: room, instance_module: Jido.Messaging.TestMessagingWithPubSub)
        server = RoomServer.via_tuple(Jido.Messaging.TestMessagingWithPubSub, room.id)

        :ok = PubSub.subscribe(Jido.Messaging.TestMessagingWithPubSub, room.id)

        participant = Participant.new(%{type: :human, identity: %{name: "Test User"}})
        :ok = RoomServer.add_participant(server, participant)

        assert_receive {:participant_joined, ^participant}, 100
      end
    end

    @tag :skip
    @tag :skip_unless_pubsub
    @tag :phase6_deprecated
    test "broadcasts participant_left event when participant is removed" do
      if PubSub.pubsub_available?() do
        room = Room.new(%{type: :direct, name: "Test Room"})
        {:ok, _pid} = RoomServer.start_link(room: room, instance_module: Jido.Messaging.TestMessagingWithPubSub)
        server = RoomServer.via_tuple(Jido.Messaging.TestMessagingWithPubSub, room.id)

        participant = Participant.new(%{type: :human, identity: %{name: "Test User"}})
        :ok = RoomServer.add_participant(server, participant)

        :ok = PubSub.subscribe(Jido.Messaging.TestMessagingWithPubSub, room.id)
        :ok = RoomServer.remove_participant(server, participant.id)

        assert_receive {:participant_left, participant_id}, 100
        assert participant_id == participant.id
      end
    end
  end

  describe "delegated functions" do
    test "subscribe/1 returns error when PubSub not configured" do
      start_supervised!(Jido.Messaging.TestMessaging)
      assert {:error, :not_configured} = Jido.Messaging.TestMessaging.subscribe("room_1")
    end

    test "unsubscribe/1 returns error when PubSub not configured" do
      start_supervised!(Jido.Messaging.TestMessaging)
      assert {:error, :not_configured} = Jido.Messaging.TestMessaging.unsubscribe("room_1")
    end

    @tag :skip_unless_pubsub
    test "subscribe/1 and unsubscribe/1 work when PubSub is configured" do
      if PubSub.pubsub_available?() do
        room_id = "test_room_#{System.unique_integer([:positive])}"

        assert :ok = Jido.Messaging.TestMessagingWithPubSub.subscribe(room_id)
        assert :ok = Jido.Messaging.TestMessagingWithPubSub.unsubscribe(room_id)
      end
    end
  end
end
