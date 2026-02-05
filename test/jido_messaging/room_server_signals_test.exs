defmodule JidoMessaging.RoomServerSignalsTest do
  @moduledoc """
  Tests for RoomServer signal emissions (Phase 1 of Bridge Refactor).

  Verifies that RoomServer emits Jido.Signal events for:
  - message_added
  - participant_joined
  - participant_left
  """
  use ExUnit.Case, async: false

  alias JidoMessaging.{Room, Message, Participant, RoomServer, RoomSupervisor}

  defmodule TestMessaging do
    use JidoMessaging, adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "message_added signal" do
    test "emits [:jido_messaging, :room, :message_added] telemetry event" do
      test_pid = self()
      handler_id = "test-message-added-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :message_added],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      room = Room.new(%{type: :group, name: "Signal Test Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_123",
          role: :user,
          content: [%{type: :text, text: "Hello signals!"}]
        })

      :ok = RoomServer.add_message(pid, message)

      assert_receive {:telemetry_event, event, measurements, metadata}, 1000

      assert event == [:jido_messaging, :room, :message_added]
      assert %DateTime{} = measurements.timestamp
      assert metadata.room_id == room.id
      assert metadata.message.id == message.id
      assert metadata.sender_id == message.sender_id

      :telemetry.detach(handler_id)
    end

    test "signal data includes room_id, message, and sender_id" do
      test_pid = self()
      handler_id = "test-message-added-data-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :message_added],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:signal_data, metadata})
        end,
        nil
      )

      room = Room.new(%{type: :direct, name: "DM Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "sender_abc",
          role: :assistant,
          content: [%{type: :text, text: "Assistant response"}]
        })

      :ok = RoomServer.add_message(pid, message)

      assert_receive {:signal_data, metadata}, 1000

      assert metadata.room_id == room.id
      assert metadata.message == message
      assert metadata.sender_id == "sender_abc"

      :telemetry.detach(handler_id)
    end
  end

  describe "participant_joined signal" do
    test "emits [:jido_messaging, :room, :participant_joined] telemetry event" do
      test_pid = self()
      handler_id = "test-participant-joined-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :participant_joined],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      room = Room.new(%{type: :group, name: "Join Test Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Alice"}})

      :ok = RoomServer.add_participant(pid, participant)

      assert_receive {:telemetry_event, event, measurements, metadata}, 1000

      assert event == [:jido_messaging, :room, :participant_joined]
      assert %DateTime{} = measurements.timestamp
      assert metadata.room_id == room.id
      assert metadata.participant.id == participant.id

      :telemetry.detach(handler_id)
    end

    test "signal data includes room_id and participant" do
      test_pid = self()
      handler_id = "test-participant-joined-data-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :participant_joined],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:signal_data, metadata})
        end,
        nil
      )

      room = Room.new(%{type: :channel, name: "Channel Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant =
        Participant.new(%{
          type: :agent,
          identity: %{name: "BotAgent"},
          presence: :online
        })

      :ok = RoomServer.add_participant(pid, participant)

      assert_receive {:signal_data, metadata}, 1000

      assert metadata.room_id == room.id
      assert metadata.participant == participant

      :telemetry.detach(handler_id)
    end
  end

  describe "participant_left signal" do
    test "emits [:jido_messaging, :room, :participant_left] telemetry event" do
      test_pid = self()
      handler_id = "test-participant-left-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :participant_left],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      room = Room.new(%{type: :group, name: "Leave Test Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Bob"}})
      :ok = RoomServer.add_participant(pid, participant)

      :ok = RoomServer.remove_participant(pid, participant.id)

      assert_receive {:telemetry_event, event, measurements, metadata}, 1000

      assert event == [:jido_messaging, :room, :participant_left]
      assert %DateTime{} = measurements.timestamp
      assert metadata.room_id == room.id
      assert metadata.participant_id == participant.id

      :telemetry.detach(handler_id)
    end

    test "signal data includes room_id and participant_id" do
      test_pid = self()
      handler_id = "test-participant-left-data-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :participant_left],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:signal_data, metadata})
        end,
        nil
      )

      room = Room.new(%{type: :direct, name: "DM Leave Room"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Charlie"}})
      :ok = RoomServer.add_participant(pid, participant)

      :ok = RoomServer.remove_participant(pid, participant.id)

      assert_receive {:signal_data, metadata}, 1000

      assert metadata.room_id == room.id
      assert metadata.participant_id == participant.id

      :telemetry.detach(handler_id)
    end
  end

  describe "Signal.emit/4 for new room events" do
    test "message_added maps to correct signal type" do
      test_pid = self()
      handler_id = "test-signal-emit-message-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :message_added],
        fn event, _measurements, _metadata, _config ->
          send(test_pid, {:event_name, event})
        end,
        nil
      )

      room = Room.new(%{type: :group, name: "Emit Test"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: []
        })

      :ok = RoomServer.add_message(pid, message)

      assert_receive {:event_name, [:jido_messaging, :room, :message_added]}, 1000

      :telemetry.detach(handler_id)
    end

    test "participant_joined maps to correct signal type" do
      test_pid = self()
      handler_id = "test-signal-emit-joined-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :participant_joined],
        fn event, _measurements, _metadata, _config ->
          send(test_pid, {:event_name, event})
        end,
        nil
      )

      room = Room.new(%{type: :group, name: "Emit Join Test"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Test"}})
      :ok = RoomServer.add_participant(pid, participant)

      assert_receive {:event_name, [:jido_messaging, :room, :participant_joined]}, 1000

      :telemetry.detach(handler_id)
    end

    test "participant_left maps to correct signal type" do
      test_pid = self()
      handler_id = "test-signal-emit-left-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :room, :participant_left],
        fn event, _measurements, _metadata, _config ->
          send(test_pid, {:event_name, event})
        end,
        nil
      )

      room = Room.new(%{type: :group, name: "Emit Left Test"})
      {:ok, pid} = RoomSupervisor.start_room(TestMessaging, room)

      participant = Participant.new(%{type: :human, identity: %{name: "Test"}})
      :ok = RoomServer.add_participant(pid, participant)
      :ok = RoomServer.remove_participant(pid, participant.id)

      assert_receive {:event_name, [:jido_messaging, :room, :participant_left]}, 1000

      :telemetry.detach(handler_id)
    end
  end
end
