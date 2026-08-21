defmodule Jido.Messaging.MessageLifecycleConcurrencyTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{MessageDeletedEvent, MessageUpdatedEvent}
  alias Jido.Chat.Content.Text
  alias Jido.Messaging.MessageLifecycle

  defmodule LifecycleGate do
    def child_spec(owner) do
      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> owner end, [name: __MODULE__]]}
      }
    end

    def role(role), do: Process.put({__MODULE__, :role}, role)

    def notify(step) do
      send(owner(), {:lifecycle_gate, step, role(), self()})
    end

    def block(step) do
      ref = make_ref()
      send(owner(), {:lifecycle_gate, step, role(), self(), ref})

      receive do
        {:continue_lifecycle, ^ref} -> :ok
      end
    end

    defp owner, do: Agent.get(__MODULE__, & &1)
    defp role, do: Process.get({__MODULE__, :role})
  end

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule InterleavingETS do
    def get_message_by_external_id(channel, bridge_id, external_id) do
      LifecycleGate.notify(:lookup)
      ETSMessaging.get_message_by_external_id(channel, bridge_id, external_id)
    end

    def save_message_struct(message) do
      LifecycleGate.block(:save)
      ETSMessaging.save_message_struct(message)
    end

    def delete_message(message_id) do
      LifecycleGate.block(:delete)
      ETSMessaging.delete_message(message_id)
    end
  end

  defmodule InterleavingSQLite do
    def get_message_by_external_id(channel, bridge_id, external_id) do
      LifecycleGate.notify(:lookup)
      SQLiteMessaging.get_message_by_external_id(channel, bridge_id, external_id)
    end

    def save_message_struct(message) do
      LifecycleGate.block(:save)
      SQLiteMessaging.save_message_struct(message)
    end

    def delete_message(message_id) do
      LifecycleGate.block(:delete)
      SQLiteMessaging.delete_message(message_id)
    end
  end

  setup do
    start_supervised!({LifecycleGate, self()})
    :ok
  end

  describe "concurrent lifecycle transitions" do
    test "ETS does not restore a message when delete races with update" do
      start_supervised!(ETSMessaging)
      exercise_serialized_transition(ETSMessaging, InterleavingETS)
    end

    test "SQLite does not restore a message when delete races with update" do
      path = temp_sqlite_path()
      on_exit(fn -> File.rm(path) end)

      start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})
      exercise_serialized_transition(SQLiteMessaging, InterleavingSQLite)
    end
  end

  describe "documentation" do
    doctest MessageLifecycle
  end

  defp exercise_serialized_transition(messaging_module, interleaving_module) do
    bridge_id = "bridge_lifecycle_race"
    external_id = "provider-message-race"

    {:ok, room} =
      messaging_module.create_room(%{
        id: "room:#{inspect(messaging_module)}",
        type: :channel,
        name: "lifecycle race"
      })

    {:ok, original} =
      messaging_module.save_message(%{
        id: "message:#{inspect(messaging_module)}",
        room_id: room.id,
        sender_id: "bot:assistant",
        role: :assistant,
        content: [%Text{text: "draft one"}],
        external_id: external_id,
        status: :sent,
        metadata: %{channel: :telegram, bridge_id: bridge_id}
      })

    update =
      MessageUpdatedEvent.new(%{
        message_id: external_id,
        message: %{id: external_id, text: "draft two"},
        timestamp: "2026-08-20T12:00:00Z"
      })

    delete =
      MessageDeletedEvent.new(%{
        message_id: external_id,
        timestamp: "2026-08-20T12:00:01Z"
      })

    update_task =
      Task.async(fn ->
        LifecycleGate.role(:update)
        MessageLifecycle.apply(interleaving_module, :telegram, bridge_id, update)
      end)

    assert_receive {:lifecycle_gate, :lookup, :update, _update_pid}
    assert_receive {:lifecycle_gate, :save, :update, update_pid, update_ref}

    test_pid = self()

    delete_task =
      Task.async(fn ->
        LifecycleGate.role(:delete)
        send(test_pid, {:delete_ready, self()})

        receive do
          :start_delete -> :ok
        end

        MessageLifecycle.apply(interleaving_module, :telegram, bridge_id, delete)
      end)

    assert_receive {:delete_ready, delete_pid}
    trace_lifecycle_lock(delete_pid)
    send(delete_pid, :start_delete)

    assert_receive {:trace, ^delete_pid, :call, {:global, :trans, [_lock, _fun]}}, 1_000
    stop_lifecycle_lock_trace(delete_pid)

    send(update_pid, {:continue_lifecycle, update_ref})
    assert {:ok, {:updated, updated}} = Task.await(update_task)
    assert [%Text{text: "draft two"}] = updated.content

    assert_receive {:lifecycle_gate, :lookup, :delete, _delete_pid}, 1_000
    assert_receive {:lifecycle_gate, :delete, :delete, delete_pid, delete_ref}, 1_000
    send(delete_pid, {:continue_lifecycle, delete_ref})

    assert {:ok, {:deleted, ^updated}} = Task.await(delete_task)
    assert {:error, :not_found} = messaging_module.get_message(original.id)
    assert {:error, :not_found} = messaging_module.get_message_by_external_id(:telegram, bridge_id, external_id)
  end

  defp trace_lifecycle_lock(pid) do
    1 = :erlang.trace(pid, true, [:call])
    1 = :erlang.trace_pattern({:global, :trans, 2}, true, [:local])

    on_exit(fn -> :erlang.trace_pattern({:global, :trans, 2}, false, [:local]) end)
  end

  defp stop_lifecycle_lock_trace(pid) do
    1 = :erlang.trace(pid, false, [:call])
    1 = :erlang.trace_pattern({:global, :trans, 2}, false, [:local])
  end

  defp temp_sqlite_path do
    Path.join(
      System.tmp_dir!(),
      "jido-message-lifecycle-race-#{System.unique_integer([:positive])}.sqlite3"
    )
  end
end
