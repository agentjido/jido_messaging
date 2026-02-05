defmodule JidoMessaging.AgentRunnerSignalsTest do
  @moduledoc """
  Tests for AgentRunner's Signal Bus subscription and lifecycle signal emission.
  Phase 4 of the Bridge Refactor.
  """
  use ExUnit.Case, async: false

  import JidoMessaging.TestHelpers

  alias JidoMessaging.{
    Room,
    Message,
    RoomServer,
    RoomSupervisor,
    AgentSupervisor
  }

  defmodule TestMessaging do
    use JidoMessaging, adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "Signal Bus subscription" do
    test "agent subscribes to Signal Bus on init" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, _room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      agent_config = %{
        name: "TestBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      {:ok, agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "test_bot", agent_config)

      # Give time for subscription
      assert_eventually(fn ->
        state = :sys.get_state(agent_pid)
        state.subscribed == true
      end)
    end
  end

  describe "signal-driven message processing" do
    test "agent receives messages via Signal Bus" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      test_pid = self()

      agent_config = %{
        name: "SignalBot",
        trigger: :all,
        handler: fn message, _context ->
          send(test_pid, {:received_via_signal, message.id})
          :noreply
        end
      }

      {:ok, agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "signal_bot", agent_config)

      # Wait for subscription
      assert_eventually(fn ->
        state = :sys.get_state(agent_pid)
        state.subscribed == true
      end)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello via signal!"}]
        })

      RoomServer.add_message(room_pid, message)

      assert_receive {:received_via_signal, message_id}, 1000
      assert message_id == message.id
    end

    test "agent only processes messages for its room" do
      room1 = Room.new(%{type: :group, name: "Room 1"})
      room2 = Room.new(%{type: :group, name: "Room 2"})
      {:ok, room1_pid} = RoomSupervisor.start_room(TestMessaging, room1)
      {:ok, room2_pid} = RoomSupervisor.start_room(TestMessaging, room2)

      test_pid = self()

      agent_config = %{
        name: "Room1Bot",
        trigger: :all,
        handler: fn message, _context ->
          send(test_pid, {:processed, message.room_id})
          :noreply
        end
      }

      {:ok, agent_pid} = AgentSupervisor.start_agent(TestMessaging, room1.id, "room1_bot", agent_config)

      # Wait for subscription
      assert_eventually(fn ->
        state = :sys.get_state(agent_pid)
        state.subscribed == true
      end)

      # Message to room2 should NOT trigger the agent in room1
      message_room2 =
        Message.new(%{
          room_id: room2.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Message to room 2"}]
        })

      RoomServer.add_message(room2_pid, message_room2)

      refute_receive {:processed, _}, 200

      # Message to room1 SHOULD trigger the agent
      message_room1 =
        Message.new(%{
          room_id: room1.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Message to room 1"}]
        })

      RoomServer.add_message(room1_pid, message_room1)

      room1_id = room1.id
      assert_receive {:processed, ^room1_id}, 1000
    end
  end

  describe "agent lifecycle signals" do
    test "agent emits triggered, started, and completed signals on success" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      # Attach telemetry handlers to capture signals
      triggered_events = :ets.new(:triggered_events, [:bag, :public])
      started_events = :ets.new(:started_events, [:bag, :public])
      completed_events = :ets.new(:completed_events, [:bag, :public])

      :telemetry.attach(
        "test-triggered",
        [:jido_messaging, :agent, :triggered],
        fn _event, _measurements, metadata, table ->
          :ets.insert(table, {:event, metadata})
        end,
        triggered_events
      )

      :telemetry.attach(
        "test-started",
        [:jido_messaging, :agent, :started],
        fn _event, _measurements, metadata, table ->
          :ets.insert(table, {:event, metadata})
        end,
        started_events
      )

      :telemetry.attach(
        "test-completed",
        [:jido_messaging, :agent, :completed],
        fn _event, _measurements, metadata, table ->
          :ets.insert(table, {:event, metadata})
        end,
        completed_events
      )

      agent_config = %{
        name: "LifecycleBot",
        trigger: :all,
        handler: fn _message, _context -> :noreply end
      }

      {:ok, agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "lifecycle_bot", agent_config)

      # Wait for subscription
      assert_eventually(fn ->
        state = :sys.get_state(agent_pid)
        state.subscribed == true
      end)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Trigger lifecycle"}]
        })

      RoomServer.add_message(room_pid, message)

      # Wait for processing
      assert_eventually(fn ->
        :ets.tab2list(completed_events) |> length() > 0
      end)

      # Verify triggered signal
      triggered = :ets.tab2list(triggered_events)
      assert length(triggered) == 1
      [{:event, triggered_meta}] = triggered
      assert triggered_meta.agent_id == "lifecycle_bot"
      assert triggered_meta.room_id == room.id

      # Verify started signal
      started = :ets.tab2list(started_events)
      assert length(started) == 1
      [{:event, started_meta}] = started
      assert started_meta.agent_id == "lifecycle_bot"

      # Verify completed signal
      completed = :ets.tab2list(completed_events)
      assert length(completed) == 1
      [{:event, completed_meta}] = completed
      assert completed_meta.agent_id == "lifecycle_bot"
      assert completed_meta.response == :noreply

      # Cleanup
      :telemetry.detach("test-triggered")
      :telemetry.detach("test-started")
      :telemetry.detach("test-completed")
    end

    test "agent emits failed signal on handler error" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      failed_events = :ets.new(:failed_events, [:bag, :public])

      :telemetry.attach(
        "test-failed",
        [:jido_messaging, :agent, :failed],
        fn _event, _measurements, metadata, table ->
          :ets.insert(table, {:event, metadata})
        end,
        failed_events
      )

      agent_config = %{
        name: "FailBot",
        trigger: :all,
        handler: fn _message, _context -> {:error, :intentional_failure} end
      }

      {:ok, agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "fail_bot", agent_config)

      # Wait for subscription
      assert_eventually(fn ->
        state = :sys.get_state(agent_pid)
        state.subscribed == true
      end)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Trigger failure"}]
        })

      RoomServer.add_message(room_pid, message)

      # Wait for processing
      assert_eventually(fn ->
        :ets.tab2list(failed_events) |> length() > 0
      end)

      failed = :ets.tab2list(failed_events)
      assert length(failed) == 1
      [{:event, failed_meta}] = failed
      assert failed_meta.agent_id == "fail_bot"
      assert failed_meta.error == ":intentional_failure"

      :telemetry.detach("test-failed")
    end

    test "agent emits completed signal with reply info when replying" do
      room = Room.new(%{type: :group, name: "Test Room"})
      {:ok, room_pid} = RoomSupervisor.start_room(TestMessaging, room)

      completed_events = :ets.new(:completed_reply_events, [:bag, :public])

      :telemetry.attach(
        "test-completed-reply",
        [:jido_messaging, :agent, :completed],
        fn _event, _measurements, metadata, table ->
          :ets.insert(table, {:event, metadata})
        end,
        completed_events
      )

      agent_config = %{
        name: "ReplyBot",
        trigger: :all,
        handler: fn _message, _context -> {:reply, "Hello back!"} end
      }

      {:ok, agent_pid} = AgentSupervisor.start_agent(TestMessaging, room.id, "reply_bot", agent_config)

      # Wait for subscription
      assert_eventually(fn ->
        state = :sys.get_state(agent_pid)
        state.subscribed == true
      end)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      RoomServer.add_message(room_pid, message)

      # Wait for processing
      assert_eventually(fn ->
        :ets.tab2list(completed_events) |> length() > 0
      end)

      completed = :ets.tab2list(completed_events)
      assert length(completed) == 1
      [{:event, completed_meta}] = completed
      assert completed_meta.agent_id == "reply_bot"
      assert completed_meta.response == :reply
      assert is_binary(completed_meta.reply_message_id)

      :telemetry.detach("test-completed-reply")
    end
  end
end
