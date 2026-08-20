defmodule Jido.Messaging.Persistence.SQLiteTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{CommandResult, Message, Persistence.SQLite, Thread}

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: SQLite
  end

  defmodule SQLiteMessagingOne do
    use Jido.Messaging, persistence: SQLite
  end

  defmodule SQLiteMessagingTwo do
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

  test "isolates direct adapter instances that share one database" do
    path = tmp_path("sqlite-instance-isolation")
    {:ok, first} = SQLite.init(path: path, instance_id: "instance-one")
    {:ok, second} = SQLite.init(path: path, instance_id: "instance-two")

    first_room = Room.new(%{id: "room:shared-id", type: :channel, name: "first"})
    second_room = Room.new(%{id: "room:shared-id", type: :channel, name: "second"})

    assert {:ok, ^first_room} = SQLite.save_room(first, first_room)
    assert {:error, :not_found} = SQLite.get_room(second, first_room.id)
    assert {:ok, ^second_room} = SQLite.save_room(second, second_room)

    assert {:ok, ^first_room} = SQLite.get_room(first, first_room.id)
    assert {:ok, ^second_room} = SQLite.get_room(second, second_room.id)

    assert :ok = SQLite.delete_room(first, first_room.id)
    assert {:error, :not_found} = SQLite.get_room(first, first_room.id)
    assert {:ok, ^second_room} = SQLite.get_room(second, second_room.id)

    :ok = Sqlite3.close(first.db)
    :ok = Sqlite3.close(second.db)
  end

  test "runtime modules receive separate default namespaces" do
    path = tmp_path("sqlite-runtime-isolation")

    start_supervised!({SQLiteMessagingOne, persistence_opts: [path: path]})
    start_supervised!({SQLiteMessagingTwo, persistence_opts: [path: path]})

    first_room = Room.new(%{id: "room:runtime-shared", type: :group, name: "runtime-one"})
    second_room = Room.new(%{id: "room:runtime-shared", type: :group, name: "runtime-two"})

    assert {:ok, ^first_room} = SQLiteMessagingOne.save_room(first_room)
    assert {:error, :not_found} = SQLiteMessagingTwo.get_room(first_room.id)
    assert {:ok, ^second_room} = SQLiteMessagingTwo.save_room(second_room)

    assert {:ok, ^first_room} = SQLiteMessagingOne.get_room(first_room.id)
    assert {:ok, ^second_room} = SQLiteMessagingTwo.get_room(second_room.id)
  end

  test "migrates legacy records into the opening instance namespace" do
    path = tmp_path("sqlite-instance-migration")
    room = Room.new(%{id: "room:legacy", type: :channel, name: "legacy"})
    create_legacy_database(path, room)

    {:ok, migrated} = SQLite.init(path: path, instance_id: "migrated-instance")
    assert {:ok, ^room} = SQLite.get_room(migrated, room.id)
    :ok = Sqlite3.close(migrated.db)

    {:ok, isolated} = SQLite.init(path: path, instance_id: "other-instance")
    assert {:error, :not_found} = SQLite.get_room(isolated, room.id)
    :ok = Sqlite3.close(isolated.db)
  end

  test "serializes concurrent legacy migration and keeps the first namespace owner" do
    path = tmp_path("sqlite-concurrent-instance-migration")
    room = Room.new(%{id: "room:legacy-race", type: :channel, name: "legacy-race"})
    create_legacy_database(path, room)

    states =
      ["migration-one", "migration-two"]
      |> Task.async_stream(fn instance_id -> SQLite.init(path: path, instance_id: instance_id) end,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, state}} -> state end)

    assert length(states) == 2

    owners = Enum.filter(states, fn state -> match?({:ok, ^room}, SQLite.get_room(state, room.id)) end)
    assert [_single_owner] = owners

    Enum.each(states, fn state -> :ok = Sqlite3.close(state.db) end)
  end

  test "scopes provider identities by bridge and supports explicit links" do
    path = tmp_path("sqlite-participant-scope")
    {:ok, state} = SQLite.init(path: path)

    assert {:ok, first} =
             SQLite.get_or_create_participant_by_external_binding(
               state,
               :slack,
               "workspace-one",
               "user-1",
               %{type: :human, identity: %{name: "First"}}
             )

    assert {:ok, second} =
             SQLite.get_or_create_participant_by_external_binding(
               state,
               :slack,
               "workspace-two",
               "user-1",
               %{type: :human, identity: %{name: "Second"}}
             )

    refute first.id == second.id

    assert :ok =
             SQLite.bind_participant_external_id(
               state,
               first.id,
               :slack,
               "workspace-three",
               "user-linked"
             )

    assert {:ok, linked} =
             SQLite.get_or_create_participant_by_external_binding(
               state,
               :slack,
               "workspace-three",
               "user-linked",
               %{}
             )

    assert linked.id == first.id

    assert {:error, {:external_identity_conflict, first_id}} =
             SQLite.bind_participant_external_id(
               state,
               second.id,
               :slack,
               "workspace-three",
               "user-linked"
             )

    assert first_id == first.id
    :ok = Sqlite3.close(state.db)
  end

  test "normalizes non-string external binding values without crashing" do
    path = tmp_path("sqlite-normalized-bindings")
    {:ok, state} = SQLite.init(path: path)

    bridge_id = {:workspace, 1}
    external_id = {:channel, 2}

    assert {:ok, room} =
             SQLite.get_or_create_room_by_external_binding(
               state,
               :slack,
               bridge_id,
               external_id,
               %{id: "room:normalized", type: :channel, name: "normalized"}
             )

    assert {:ok, ^room} = SQLite.get_room_by_external_binding(state, :slack, bridge_id, external_id)

    assert {:ok, [^room]} =
             SQLite.directory_search(
               state,
               :room,
               %{
                 channel: :slack,
                 bridge_id: bridge_id,
                 external_id: external_id
               },
               []
             )

    :ok = Sqlite3.close(state.db)
  end

  test "bind errors release statements and leave the adapter usable" do
    path = tmp_path("sqlite-bind-error")
    {:ok, state} = SQLite.init(path: path)

    room = Room.new(%{id: "room:bind-error", type: :channel, name: "bind-error"})

    message =
      Message.new(%{
        id: "message:bind-error",
        room_id: room.id,
        sender_id: "user:1",
        role: :user,
        content: [%{type: "text", text: "still readable"}],
        status: :sent
      })

    assert {:ok, ^room} = SQLite.save_room(state, room)
    assert {:ok, ^message} = SQLite.save_message(state, message)

    assert {:error, %ArgumentError{}} = SQLite.get_messages(state, room.id, limit: %{bad: true})
    assert {:ok, [^message]} = SQLite.get_messages(state, room.id, limit: 10)

    :ok = Sqlite3.close(state.db)
  end

  test "paginates before and after a stable message cursor" do
    path = tmp_path("sqlite-cursors")
    {:ok, state} = SQLite.init(path: path)
    room = Room.new(%{id: "room:cursors", type: :channel, name: "cursors"})
    assert {:ok, ^room} = SQLite.save_room(state, room)

    messages = pagination_messages(room.id)
    Enum.each(messages, &SQLite.save_message(state, &1))

    assert {:ok, latest} = SQLite.get_messages(state, room.id, limit: 2)
    assert Enum.map(latest, & &1.id) == ["message:3", "message:4"]

    assert {:ok, older} = SQLite.get_messages(state, room.id, before: "message:3", limit: 2)
    assert Enum.map(older, & &1.id) == ["message:1", "message:2"]

    assert {:ok, newer} = SQLite.get_messages(state, room.id, after: "message:2", limit: 2)
    assert Enum.map(newer, & &1.id) == ["message:3", "message:4"]

    assert {:error, :cursor_not_found} = SQLite.get_messages(state, room.id, after: "missing")

    assert {:error, :invalid_cursor_options} =
             SQLite.get_messages(state, room.id, before: "message:3", after: "message:2")

    :ok = Sqlite3.close(state.db)
  end

  test "traverses cursor boundaries and rejects stale or out-of-scope cursors" do
    path = tmp_path("sqlite-cursor-boundaries")
    {:ok, state} = SQLite.init(path: path)
    room = Room.new(%{id: "room:cursor-boundaries", type: :channel, name: "cursor-boundaries"})
    assert {:ok, ^room} = SQLite.save_room(state, room)

    messages = pagination_messages(room.id)
    Enum.each(messages, &SQLite.save_message(state, &1))

    assert {:ok, first_page} = SQLite.get_messages(state, room.id, limit: 2)
    assert {:ok, second_page} = SQLite.get_messages(state, room.id, before: hd(first_page).id, limit: 2)
    assert Enum.map(second_page ++ first_page, & &1.id) == Enum.map(messages, & &1.id)

    assert {:ok, []} = SQLite.get_messages(state, room.id, before: hd(messages).id, limit: 2)
    assert {:ok, []} = SQLite.get_messages(state, room.id, after: List.last(messages).id, limit: 2)

    assert :ok = SQLite.delete_message(state, "message:2")
    assert {:error, :cursor_not_found} = SQLite.get_messages(state, room.id, after: "message:2")

    thread_cursor = pagination_message("message:thread-cursor", room.id, hd(messages).inserted_at, "thread:one")
    thread_message = pagination_message("message:thread", room.id, List.last(messages).inserted_at, "thread:one")
    assert {:ok, _message} = SQLite.save_message(state, thread_cursor)
    assert {:ok, _message} = SQLite.save_message(state, thread_message)

    assert {:ok, [^thread_message]} =
             SQLite.get_messages(state, room.id, thread_id: "thread:one", after: thread_cursor.id)

    assert {:error, :cursor_not_found} =
             SQLite.get_messages(state, room.id, thread_id: "thread:other", after: thread_cursor.id)

    :ok = Sqlite3.close(state.db)
  end

  test "orders imported messages without timestamps consistently with ETS" do
    path = tmp_path("sqlite-cursor-null-time")
    {:ok, state} = SQLite.init(path: path)
    room = Room.new(%{id: "room:cursor-null-time", type: :channel, name: "cursor-null-time"})
    assert {:ok, ^room} = SQLite.save_room(state, room)

    missing_timestamp = pagination_message("message:missing-time", room.id, nil)
    timestamped = pagination_message("message:timestamped", room.id, ~U[2026-01-01 00:00:00Z])
    assert {:ok, _message} = SQLite.save_message(state, timestamped)
    assert {:ok, _message} = SQLite.save_message(state, missing_timestamp)

    assert {:ok, [^missing_timestamp, ^timestamped]} = SQLite.get_messages(state, room.id)
    assert {:ok, [^timestamped]} = SQLite.get_messages(state, room.id, after: missing_timestamp.id)

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

  defp pagination_messages(room_id) do
    base = ~U[2026-01-01 00:00:00.000000Z]

    [
      pagination_message("message:1", room_id, base),
      pagination_message("message:2", room_id, DateTime.add(base, 1, :second)),
      pagination_message("message:3", room_id, DateTime.add(base, 1, :second)),
      pagination_message("message:4", room_id, DateTime.add(base, 2, :second))
    ]
  end

  defp pagination_message(id, room_id, inserted_at, thread_id \\ nil) do
    Message.new(%{
      id: id,
      room_id: room_id,
      sender_id: "user:cursor",
      role: :user,
      content: [%{type: :text, text: id}],
      inserted_at: inserted_at,
      thread_id: thread_id
    })
  end

  defp create_legacy_database(path, room) do
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE jido_messaging_records (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        room_id TEXT,
        thread_id TEXT,
        inserted_at TEXT,
        channel TEXT,
        bridge_id TEXT,
        external_id TEXT,
        payload BLOB NOT NULL,
        PRIMARY KEY (kind, id)
      )
      """)

    {:ok, statement} =
      Sqlite3.prepare(
        db,
        """
        INSERT INTO jido_messaging_records
          (kind, id, room_id, payload)
        VALUES (?1, ?2, ?3, ?4)
        """
      )

    :ok = Sqlite3.bind(statement, ["room", room.id, room.id, {:blob, :erlang.term_to_binary(room)}])
    :done = Sqlite3.step(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
  end
end
