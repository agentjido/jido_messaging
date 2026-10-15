defmodule Jido.Messaging.Persistence.StorageBoundaryRegressionTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Room
  alias Jido.Messaging.{Message, Persistence, Query, Thread}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ] do
    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} message updates replace all old scope indexes" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      for id <- ["old-room", "new-room"] do
        room = Room.new(%{id: id, type: :group})
        assert {:ok, ^room} = adapter.save_room(state, room)
      end

      original =
        Message.new(%{
          id: "moving",
          room_id: "old-room",
          sender_id: "sender",
          role: :user,
          thread_id: "old-thread",
          external_id: "old-provider-id",
          metadata: %{channel: :slack, bridge_id: "bridge"}
        })

      assert {:ok, ^original} = adapter.save_message(state, original)
      updated = %{original | room_id: "new-room", thread_id: "new-thread", external_id: "new-provider-id"}
      assert {:ok, ^updated} = adapter.save_message(state, updated)

      assert {:error, :not_found} =
               adapter.get_message_by_external_id(state, :slack, "bridge", "old-provider-id", "old-room")

      assert {:ok, ^updated} =
               adapter.get_message_by_external_id(state, :slack, "bridge", "new-provider-id", "new-room")

      assert {:ok, []} = adapter.get_messages(state, "new-room", thread_id: "old-thread")
      assert :ok = adapter.delete_room(state, "old-room")
      assert {:ok, ^updated} = adapter.get_message(state, updated.id)
      assert {:ok, [^updated]} = adapter.get_messages(state, "new-room", thread_id: "new-thread")
    end

    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} history orders UTC instants across precision and offsets" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      offset = %{~U[2026-01-01 01:00:00.250000Z] | utc_offset: 3_600}

      messages =
        for {id, date} <- [
              {"a-whole", ~U[2026-01-01 00:00:00Z]},
              {"b-equal", ~U[2026-01-01 00:00:00.000000Z]},
              {"c-offset", offset},
              {"d-fraction", ~U[2026-01-01 00:00:00.500000Z]}
            ] do
          Message.new(%{id: id, room_id: "room", sender_id: "sender", role: :user, inserted_at: date})
        end

      for message <- Enum.reverse(messages), do: assert({:ok, message} == adapter.save_message(state, message))
      [first, second, third, last] = messages
      assert {:ok, ^messages} = adapter.get_messages(state, "room", limit: 10)
      assert {:ok, [^last]} = adapter.get_messages(state, "room", limit: 1)
      assert {:ok, [^second, ^third, ^last]} = adapter.get_messages(state, "room", after: first.id)

      assert {:ok, [^first, ^second, ^third]} =
               adapter.get_participant_messages(state, "sender", ["room"], before: last.id)

      assert Query.room_timeline(messages).messages == messages
    end

    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} room bindings retain one owner and same-room retry" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      first = Room.new(%{id: "first", type: :group})
      second = Room.new(%{id: "second", type: :group})
      for room <- [first, second], do: assert({:ok, room} == adapter.save_room(state, room))
      assert {:ok, binding} = adapter.create_room_binding(state, first.id, :slack, "bridge", "external", %{})
      assert {:ok, ^binding} = adapter.create_room_binding(state, first.id, :slack, "bridge", "external", %{})

      assert {:error, {:room_binding_conflict, "first"}} =
               adapter.create_room_binding(state, second.id, :slack, "bridge", "external", %{})

      assert {:ok, ^first} = adapter.get_room_by_external_binding(state, :slack, "bridge", "external")
      assert {:ok, [^binding]} = adapter.list_room_bindings(state, first.id)
      assert {:ok, []} = adapter.list_room_bindings(state, second.id)
      assert :ok = adapter.delete_room(state, second.id)
      assert {:ok, ^first} = adapter.get_room_by_external_binding(state, :slack, "bridge", "external")
    end

    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} root-message lookup reaches records after the first page" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      for index <- 1..501 do
        thread =
          Thread.new(%{
            id: "thread-" <> String.pad_leading(to_string(index), 3, "0"),
            room_id: "room",
            root_message_id: "root-#{index}",
            inserted_at: DateTime.add(~U[2026-01-01 00:00:00Z], index)
          })

        assert {:ok, ^thread} = adapter.save_thread(state, thread)
      end

      assert {:ok, wanted} = adapter.get_thread(state, "thread-501")
      foreign = %{wanted | id: "foreign-thread", room_id: "foreign-room"}
      assert {:ok, ^foreign} = adapter.save_thread(state, foreign)
      assert {:ok, ^wanted} = adapter.get_thread_by_root_message(state, "room", "root-501")
      assert {:error, :not_found} = adapter.get_thread_by_root_message(state, "room", "absent")
    end
  end

  test "SQLite startup normalizes stored history keys without changing message cursors or payloads" do
    {:ok, state} = Factory.start_sqlite()
    path = state.path
    on_exit(fn -> File.rm(path) end)

    first =
      Message.new(%{
        id: "whole",
        room_id: "room",
        sender_id: "sender",
        role: :user,
        inserted_at: ~U[2026-01-01 00:00:00Z]
      })

    later = %{first | id: "fraction", inserted_at: ~U[2026-01-01 00:00:00.500000Z]}

    for message <- [first, later] do
      assert {:ok, ^message} = Persistence.SQLite.save_message(state, message)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          state.db,
          "UPDATE jido_messaging_records SET inserted_at = ?1 WHERE kind = 'message' AND id = ?2"
        )

      :ok = Exqlite.Sqlite3.bind(statement, [DateTime.to_iso8601(message.inserted_at), message.id])
      assert :done = Exqlite.Sqlite3.step(state.db, statement)
      :ok = Exqlite.Sqlite3.release(state.db, statement)
    end

    :ok = Persistence.SQLite.close(state)
    {:ok, migrated} = Persistence.SQLite.init(path: path)
    on_exit(fn -> Persistence.SQLite.close(migrated) end)
    assert {:ok, [^first, ^later]} = Persistence.SQLite.get_messages(migrated, "room", limit: 10)
    assert {:ok, [^later]} = Persistence.SQLite.get_messages(migrated, "room", after: first.id)
    assert {:ok, [^first]} = Persistence.SQLite.get_messages(migrated, "room", before: later.id)
    assert {:ok, ^first} = Persistence.SQLite.get_message(migrated, first.id)
  end
end
