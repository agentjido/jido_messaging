defmodule Jido.Messaging.AgentRunnerSignalsTest do
  use ExUnit.Case, async: false

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.AgentRunner

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "runner lifecycle" do
    test "assigned runners subscribe to the signal bus" do
      %{room: room, thread: thread} = room_with_assignment("alpha", fn _, _ -> :noreply end)

      pid = AgentRunner.whereis(TestMessaging, room.id, thread.id, "alpha")
      assert is_pid(pid)

      assert_eventually(fn ->
        :sys.get_state(pid).subscribed == true
      end)
    end
  end

  describe "agent lifecycle telemetry" do
    test "emits triggered, started, and completed for successful processing" do
      test_pid = self()

      %{room: room, thread: thread, room_pid: room_pid} =
        room_with_assignment("alpha", fn _message, _context ->
          :noreply
        end)

      handler_ids =
        attach_signal_handlers(test_pid, [
          [:jido_messaging, :agent, :triggered],
          [:jido_messaging, :agent, :started],
          [:jido_messaging, :agent, :completed]
        ])

      on_exit(fn -> Enum.each(handler_ids, &:telemetry.detach/1) end)

      :ok =
        Jido.Messaging.RoomServer.add_message(
          room_pid,
          persisted_message(%{
            room_id: room.id,
            sender_id: "user-1",
            role: :user,
            content: [%{type: :text, text: "hello"}],
            thread_id: thread.id
          }),
          nil
        )

      assert_receive {:agent_signal, [:jido_messaging, :agent, :triggered], triggered}, 1_000
      assert_receive {:agent_signal, [:jido_messaging, :agent, :started], started}, 1_000
      assert_receive {:agent_signal, [:jido_messaging, :agent, :completed], completed}, 1_000

      assert triggered.agent_id == "alpha"
      assert triggered.room_id == room.id
      assert triggered.thread_id == thread.id

      assert started.agent_id == "alpha"
      assert started.thread_id == thread.id

      assert completed.agent_id == "alpha"
      assert completed.thread_id == thread.id
      assert completed.response == :noreply
    end

    test "emits failed when the handler returns an error" do
      test_pid = self()

      %{room: room, thread: thread, room_pid: room_pid} =
        room_with_assignment("alpha", fn _message, _context ->
          {:error, :intentional_failure}
        end)

      handler_ids = attach_signal_handlers(test_pid, [[:jido_messaging, :agent, :failed]])
      on_exit(fn -> Enum.each(handler_ids, &:telemetry.detach/1) end)

      :ok =
        Jido.Messaging.RoomServer.add_message(
          room_pid,
          persisted_message(%{
            room_id: room.id,
            sender_id: "user-1",
            role: :user,
            content: [%{type: :text, text: "hello"}],
            thread_id: thread.id
          }),
          nil
        )

      assert_receive {:agent_signal, [:jido_messaging, :agent, :failed], failed}, 1_000
      assert failed.agent_id == "alpha"
      assert failed.room_id == room.id
      assert failed.thread_id == thread.id
      assert failed.error == ":intentional_failure"
    end
  end

  defp persisted_message(attrs) do
    {:ok, message} = TestMessaging.save_message(attrs)
    message
  end

  defp room_with_assignment(agent_id, handler) do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Signal Test"})

    {:ok, thread} =
      TestMessaging.save_thread(%{
        room_id: room.id,
        external_thread_id: "thread-1",
        delivery_external_room_id: "delivery-thread-1"
      })

    {:ok, _spec} =
      TestMessaging.register_agent(room.id, %{
        agent_id: agent_id,
        name: String.capitalize(agent_id),
        handler: handler
      })

    {:ok, _assigned_thread} = TestMessaging.assign_thread(room.id, thread.id, agent_id)
    {:ok, room_pid} = TestMessaging.get_or_start_room_server(room)
    runner = AgentRunner.whereis(TestMessaging, room.id, thread.id, agent_id)
    assert_eventually(fn -> AgentRunner.get_state(runner).subscribed end)

    %{room: room, thread: thread, room_pid: room_pid}
  end

  defp attach_signal_handlers(test_pid, events) do
    Enum.map(events, fn event ->
      handler_id =
        "agent-signal-#{Enum.join(Enum.map(event, &Atom.to_string/1), "-")}-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        event,
        fn event_name, _measurements, metadata, pid ->
          send(pid, {:agent_signal, event_name, metadata})
        end,
        test_pid
      )

      handler_id
    end)
  end
end
