defmodule Jido.Chat.RoomServerTest do
  use ExUnit.Case, async: true

  import Jido.Messaging.TestHelpers

  alias Jido.Chat.{LegacyMessage, Participant, Room}
  alias Jido.Messaging.{RoomServer, RoomSupervisor}

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "RoomServer lifecycle" do
    test "starts a room server via supervisor" do
      room = Room.new(%{type: :group, name: "Test Room"})
      assert {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "stops a room server" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      ref = Process.monitor(pid)
      assert :ok = RoomSupervisor.stop_room(TestMessaging, room.id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      # Registry cleanup may lag slightly behind process termination
      assert_eventually(fn -> RoomServer.whereis(TestMessaging, room.id) == nil end)
    end

    test "stop_room returns error when room not found" do
      assert {:error, :not_found} = RoomSupervisor.stop_room(TestMessaging, "nonexistent")
    end

    test "whereis returns pid for running room" do
      room = Room.new(%{type: :direct, name: "DM"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      assert RoomServer.whereis(TestMessaging, room.id) == pid
    end

    test "whereis returns nil for non-running room" do
      assert nil == RoomServer.whereis(TestMessaging, "nonexistent_room")
    end

    test "get_or_start_room starts new room if not running" do
      room = Room.new(%{type: :channel, name: "Channel"})
      assert {:ok, pid} = RoomSupervisor.get_or_start_room(TestMessaging, room)
      assert is_pid(pid)
    end

    test "get_or_start_room returns existing room if already running" do
      room = Room.new(%{type: :channel, name: "Channel"})
      {:ok, pid1} = RoomSupervisor.start_room(TestMessaging, room)
      {:ok, pid2} = RoomSupervisor.get_or_start_room(TestMessaging, room)

      assert pid1 == pid2
    end

    test "list_rooms returns running room servers" do
      room1 = Room.new(%{type: :group, name: "Room 1"})
      room2 = Room.new(%{type: :group, name: "Room 2"})

      {:ok, pid1} = RoomSupervisor.start_room(TestMessaging, room1)
      {:ok, pid2} = RoomSupervisor.start_room(TestMessaging, room2)

      rooms = RoomSupervisor.list_rooms(TestMessaging)
      assert length(rooms) == 2
      assert {room1.id, pid1} in rooms
      assert {room2.id, pid2} in rooms
    end

    test "count_rooms returns correct count" do
      assert RoomSupervisor.count_rooms(TestMessaging) == 0

      room1 = Room.new(%{type: :group, name: "Room 1"})
      room2 = Room.new(%{type: :group, name: "Room 2"})

      {:ok, _} = RoomSupervisor.start_room(TestMessaging, room1)
      assert RoomSupervisor.count_rooms(TestMessaging) == 1

      {:ok, _} = RoomSupervisor.start_room(TestMessaging, room2)
      assert RoomSupervisor.count_rooms(TestMessaging) == 2
    end
  end

  describe "RoomServer state" do
    test "get_state returns full state" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      state = RoomServer.get_state(pid)

      assert %RoomServer{} = state
      assert state.room.id == room.id
      assert state.instance_module == TestMessaging
      assert state.messages == []
      assert state.participants == %{}
    end

    test "get_room returns room struct" do
      room = Room.new(%{type: :direct, name: "DM"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      assert RoomServer.get_room(pid) == room
    end
  end

  describe "message history" do
    test "add_message adds message to history" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      message =
        LegacyMessage.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      assert :ok = RoomServer.add_message(pid, message)

      messages = RoomServer.get_messages(pid)
      assert length(messages) == 1
      assert hd(messages).id == message.id
    end

    test "messages are ordered newest first" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      msg1 = LegacyMessage.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})
      msg2 = LegacyMessage.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})
      msg3 = LegacyMessage.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})

      RoomServer.add_message(pid, msg1)
      RoomServer.add_message(pid, msg2)
      RoomServer.add_message(pid, msg3)

      messages = RoomServer.get_messages(pid)
      assert [m3, m2, m1] = messages
      assert m1.id == msg1.id
      assert m2.id == msg2.id
      assert m3.id == msg3.id
    end

    test "get_messages with limit returns limited results" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      for i <- 1..10 do
        msg =
          LegacyMessage.new(%{
            room_id: room.id,
            sender_id: "user_1",
            role: :user,
            content: [%{type: :text, text: "LegacyMessage #{i}"}]
          })

        RoomServer.add_message(pid, msg)
      end

      messages = RoomServer.get_messages(pid, limit: 5)
      assert length(messages) == 5
    end

    test "message history respects bounded limit" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room, message_limit: 5)

      for i <- 1..10 do
        msg =
          LegacyMessage.new(%{
            room_id: room.id,
            sender_id: "user_1",
            role: :user,
            content: [%{type: :text, text: "LegacyMessage #{i}"}]
          })

        RoomServer.add_message(pid, msg)
      end

      messages = RoomServer.get_messages(pid)
      assert length(messages) == 5
    end
  end

  describe "participant management" do
    test "add_participant adds participant to room" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Alice"}})

      assert :ok = RoomServer.add_participant(pid, participant)

      participants = RoomServer.get_participants(pid)
      assert length(participants) == 1
      assert hd(participants).id == participant.id
    end

    test "add_participant updates existing participant" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Alice"}})
      RoomServer.add_participant(pid, participant)

      updated = %{participant | presence: :online}
      RoomServer.add_participant(pid, updated)

      participants = RoomServer.get_participants(pid)
      assert length(participants) == 1
      assert hd(participants).presence == :online
    end

    test "remove_participant removes participant from room" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      p1 = Participant.new(%{type: :human, identity: %{name: "Alice"}})
      p2 = Participant.new(%{type: :human, identity: %{name: "Bob"}})

      RoomServer.add_participant(pid, p1)
      RoomServer.add_participant(pid, p2)

      assert length(RoomServer.get_participants(pid)) == 2

      RoomServer.remove_participant(pid, p1.id)

      participants = RoomServer.get_participants(pid)
      assert length(participants) == 1
      assert hd(participants).id == p2.id
    end

    test "get_participants returns empty list for room with no participants" do
      room = Room.new(%{type: :direct, name: "DM"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      assert RoomServer.get_participants(pid) == []
    end
  end

  describe "timeout/hibernation" do
    test "room server hibernates after timeout" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room, timeout_ms: 50)

      Process.sleep(100)

      assert Process.alive?(pid)

      {:current_function, {_mod, func, _arity}} = Process.info(pid, :current_function)
      assert func in [:hibernate, :loop_hibernate]
    end

    test "activity resets timeout" do
      room = Room.new(%{type: :group, name: "Chat"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room, timeout_ms: 100)

      Process.sleep(50)
      RoomServer.get_state(pid)
      Process.sleep(50)
      RoomServer.get_state(pid)

      {:current_function, {_mod, func, _arity}} = Process.info(pid, :current_function)
      assert func not in [:hibernate, :loop_hibernate]
    end
  end

  describe "delegated functions in instance module" do
    test "start_room_server delegates to RoomSupervisor" do
      room = Room.new(%{type: :group, name: "Test"})
      assert {:ok, pid} = TestMessaging.start_room_server(room)
      assert is_pid(pid)
    end

    test "get_or_start_room_server delegates to RoomSupervisor" do
      room = Room.new(%{type: :group, name: "Test"})
      assert {:ok, pid} = TestMessaging.get_or_start_room_server(room)
      assert is_pid(pid)
    end

    test "stop_room_server delegates to RoomSupervisor" do
      room = Room.new(%{type: :group, name: "Test"})
      {:ok, _pid} = TestMessaging.start_room_server(room)
      assert :ok = TestMessaging.stop_room_server(room.id)
    end

    test "whereis_room_server delegates to RoomServer" do
      room = Room.new(%{type: :group, name: "Test"})
      {:ok, pid} = TestMessaging.start_room_server(room)
      assert TestMessaging.whereis_room_server(room.id) == pid
    end

    test "list_room_servers delegates to RoomSupervisor" do
      room = Room.new(%{type: :group, name: "Test"})
      {:ok, pid} = TestMessaging.start_room_server(room)

      rooms = TestMessaging.list_room_servers()
      assert {room.id, pid} in rooms
    end

    test "count_room_servers delegates to RoomSupervisor" do
      assert TestMessaging.count_room_servers() == 0

      room = Room.new(%{type: :group, name: "Test"})
      {:ok, _pid} = TestMessaging.start_room_server(room)

      assert TestMessaging.count_room_servers() == 1
    end

    test "__jido_messaging__ returns room registry and supervisor names" do
      assert TestMessaging.__jido_messaging__(:room_registry) ==
               Module.concat(TestMessaging, Registry.Rooms)

      assert TestMessaging.__jido_messaging__(:room_supervisor) ==
               Module.concat(TestMessaging, :RoomSupervisor)
    end
  end
end
