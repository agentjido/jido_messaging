defmodule Jido.Messaging.Persistence.SQLiteTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{CommandResult, Message, Persistence.SQLite, Thread}

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: SQLite
  end

  test "persists rooms, participants, threads, and messages across adapter restarts" do
    path = tmp_path("sqlite-durable")
    {:ok, state} = SQLite.init(path: path)

    room =
      Room.new(%{
        id: "room:durable",
        type: :channel,
        name: "durable"
      })

    participant =
      Participant.new(%{
        id: "user:durable",
        type: :human,
        identity: %{name: "Durable User", initials: "DU"},
        presence: :online
      })

    thread =
      Thread.new(%{
        id: "thread:durable",
        room_id: room.id,
        root_message_id: "message:root"
      })

    message =
      Message.new(%{
        id: "message:durable",
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: [%{type: "text", text: "survives restart"}],
        status: :sent
      })

    assert {:ok, ^room} = SQLite.save_room(state, room)
    assert {:ok, ^participant} = SQLite.save_participant(state, participant)
    assert {:ok, ^thread} = SQLite.save_thread(state, thread)
    assert {:ok, ^message} = SQLite.save_message(state, message)
    :ok = Sqlite3.close(state.db)

    {:ok, restarted} = SQLite.init(path: path)

    assert {:ok, ^room} = SQLite.get_room(restarted, room.id)
    assert {:ok, ^participant} = SQLite.get_participant(restarted, participant.id)
    assert {:ok, ^thread} = SQLite.get_thread(restarted, thread.id)
    assert {:ok, [^message]} = SQLite.get_messages(restarted, room.id, limit: 10)

    :ok = Sqlite3.close(restarted.db)
  end

  test "resolves external bindings and message external IDs directly from SQLite" do
    path = tmp_path("sqlite-bindings")
    {:ok, state} = SQLite.init(path: path)

    assert {:ok, room} =
             SQLite.get_or_create_room_by_external_binding(
               state,
               :slack,
               "workspace-1",
               "C123",
               %{id: "room:slack", type: :channel, name: "slack-room"}
             )

    assert {:ok, ^room} = SQLite.get_room_by_external_binding(state, :slack, "workspace-1", "C123")

    assert {:ok, participant} =
             SQLite.get_or_create_participant_by_external_id(
               state,
               :slack,
               "U123",
               %{id: "user:slack", type: :human, identity: %{name: "Slack User"}}
             )

    assert {:ok, ^participant} =
             SQLite.directory_lookup(state, :participant, %{channel: :slack, external_id: "U123"})

    message =
      Message.new(%{
        id: "message:external",
        room_id: room.id,
        sender_id: participant.id,
        role: :user,
        content: [%{type: "text", text: "external id"}],
        external_id: "166000.100",
        status: :sent,
        metadata: %{channel: :slack, bridge_id: "workspace-1"}
      })

    assert {:ok, ^message} = SQLite.save_message(state, message)
    assert {:ok, ^message} = SQLite.get_message_by_external_id(state, :slack, "workspace-1", "166000.100")

    :ok = Sqlite3.close(state.db)
  end

  test "room_timeline returns raw timeline messages and thread replies" do
    path = tmp_path("sqlite-query")
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    assert {:ok, room} = SQLiteMessaging.create_room(%{id: "room:timeline", type: :group, name: "timeline"})

    assert {:ok, %CommandResult{record: root}} =
             SQLiteMessaging.post_message(%{
               room_id: room.id,
               sender_id: "user:1",
               role: :user,
               content: [%{type: "text", text: "root"}],
               status: :sent
             })

    assert {:ok, %CommandResult{record: reply}} =
             SQLiteMessaging.post_message(%{
               room_id: room.id,
               sender_id: "user:2",
               role: :user,
               content: [%{type: "text", text: "reply"}],
               thread_id: root.id,
               reply_to_id: root.id,
               status: :sent
             })

    assert {:ok, timeline} = SQLiteMessaging.room_timeline(room.id, limit: 10)

    assert [%Message{id: root_id}] = timeline.messages
    assert root_id == root.id
    assert %{^root_id => [%Message{id: reply_id}]} = timeline.threads
    assert reply_id == reply.id
    assert timeline.reply_counts[root.id] == 1
  end

  defp tmp_path(prefix) do
    path = Path.join(["tmp", "#{prefix}-#{System.unique_integer([:positive])}.sqlite3"])
    File.rm(path)
    path
  end
end
