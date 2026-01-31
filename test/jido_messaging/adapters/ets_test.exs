defmodule JidoMessaging.Adapters.ETSTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Adapters.ETS
  alias JidoMessaging.{Room, Participant, Message}

  setup do
    {:ok, state} = ETS.init([])
    {:ok, state: state}
  end

  describe "init/1" do
    test "creates anonymous ETS tables" do
      {:ok, state} = ETS.init([])

      assert is_reference(state.rooms)
      assert is_reference(state.participants)
      assert is_reference(state.messages)
      assert is_reference(state.room_messages)
      assert is_reference(state.room_bindings)
      assert is_reference(state.participant_bindings)
    end
  end

  describe "room operations" do
    test "save_room/2 and get_room/2", %{state: state} do
      room = Room.new(%{type: :direct, name: "Test Room"})

      assert {:ok, saved_room} = ETS.save_room(state, room)
      assert saved_room.id == room.id

      assert {:ok, fetched_room} = ETS.get_room(state, room.id)
      assert fetched_room.id == room.id
      assert fetched_room.name == "Test Room"
    end

    test "get_room/2 returns error for non-existent room", %{state: state} do
      assert {:error, :not_found} = ETS.get_room(state, "non_existent")
    end

    test "delete_room/2 removes room", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      assert :ok = ETS.delete_room(state, room.id)
      assert {:error, :not_found} = ETS.get_room(state, room.id)
    end

    test "list_rooms/2 returns all rooms", %{state: state} do
      room1 = Room.new(%{type: :direct})
      room2 = Room.new(%{type: :group})

      {:ok, _} = ETS.save_room(state, room1)
      {:ok, _} = ETS.save_room(state, room2)

      {:ok, rooms} = ETS.list_rooms(state)
      assert length(rooms) == 2
    end

    test "list_rooms/2 respects limit", %{state: state} do
      for _ <- 1..5, do: ETS.save_room(state, Room.new(%{type: :direct}))

      {:ok, rooms} = ETS.list_rooms(state, limit: 3)
      assert length(rooms) == 3
    end
  end

  describe "participant operations" do
    test "save_participant/2 and get_participant/2", %{state: state} do
      participant = Participant.new(%{type: :human, identity: %{name: "Alice"}})

      assert {:ok, _saved} = ETS.save_participant(state, participant)
      assert {:ok, fetched} = ETS.get_participant(state, participant.id)
      assert fetched.identity.name == "Alice"
    end

    test "get_participant/2 returns error for non-existent", %{state: state} do
      assert {:error, :not_found} = ETS.get_participant(state, "non_existent")
    end

    test "delete_participant/2 removes participant", %{state: state} do
      participant = Participant.new(%{type: :agent})
      {:ok, _} = ETS.save_participant(state, participant)

      assert :ok = ETS.delete_participant(state, participant.id)
      assert {:error, :not_found} = ETS.get_participant(state, participant.id)
    end
  end

  describe "message operations" do
    test "save_message/2 and get_message/2", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello"}]
        })

      assert {:ok, _saved} = ETS.save_message(state, message)
      assert {:ok, fetched} = ETS.get_message(state, message.id)
      assert fetched.content == [%{type: :text, text: "Hello"}]
    end

    test "get_messages/3 returns messages for room", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      msg1 = Message.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})
      msg2 = Message.new(%{room_id: room.id, sender_id: "u2", role: :user, content: []})

      {:ok, _} = ETS.save_message(state, msg1)
      {:ok, _} = ETS.save_message(state, msg2)

      {:ok, messages} = ETS.get_messages(state, room.id)
      assert length(messages) == 2
    end

    test "get_messages/3 respects limit", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      for i <- 1..10 do
        msg = Message.new(%{room_id: room.id, sender_id: "u#{i}", role: :user, content: []})
        ETS.save_message(state, msg)
      end

      {:ok, messages} = ETS.get_messages(state, room.id, limit: 5)
      assert length(messages) == 5
    end

    test "delete_message/2 removes message from index", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      message = Message.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})
      {:ok, _} = ETS.save_message(state, message)

      assert :ok = ETS.delete_message(state, message.id)
      assert {:error, :not_found} = ETS.get_message(state, message.id)

      {:ok, messages} = ETS.get_messages(state, room.id)
      assert messages == []
    end
  end

  describe "external binding operations" do
    test "get_or_create_room_by_external_binding/5 creates room on first call", %{state: state} do
      {:ok, room} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :direct}
        )

      assert room.type == :direct
      assert room.external_bindings == %{telegram: %{"bot_1" => "chat_123"}}
    end

    test "get_or_create_room_by_external_binding/5 returns existing room", %{state: state} do
      {:ok, room1} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :direct}
        )

      {:ok, room2} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :group}
        )

      assert room1.id == room2.id
    end

    test "get_or_create_participant_by_external_id/4 creates participant on first call", %{
      state: state
    } do
      {:ok, participant} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_456",
          %{type: :human, identity: %{name: "Bob"}}
        )

      assert participant.type == :human
      assert participant.external_ids == %{telegram: "user_456"}
    end

    test "get_or_create_participant_by_external_id/4 returns existing participant", %{
      state: state
    } do
      {:ok, p1} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_456",
          %{type: :human}
        )

      {:ok, p2} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_456",
          %{type: :agent}
        )

      assert p1.id == p2.id
    end
  end
end
