defmodule Jido.Messaging.Persistence.CheckpointStorageContractTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{ExternalIdentityBinding, Message, Persistence, Thread}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} absent records and empty scoped history have explicit results" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      room = Room.new(%{id: "owned-room", type: :group})
      person = Participant.new(%{id: "owned-person", type: :human})
      assert {:ok, ^room} = adapter.save_room(state, room)
      assert {:ok, ^person} = adapter.save_participant(state, person)
      assert {:ok, []} = adapter.get_messages(state, room.id)
      assert {:ok, []} = adapter.get_participant_messages(state, person.id, [room.id])
      assert {:ok, []} = adapter.get_principal_activity(state, person.id, [room.id])
      assert {:error, :not_found} = adapter.get_thread(state, "missing")
      assert {:error, :not_found} = adapter.get_thread_by_external_id(state, room.id, "missing")
      assert {:error, :not_found} = adapter.get_thread_by_root_message(state, room.id, "missing")
      assert {:error, :not_found} = adapter.get_message_by_external_id(state, :test, "owned", "missing")
      assert {:error, :not_found} = adapter.get_message_by_external_id(state, :test, "owned", "missing", room.id)
      assert {:error, :not_found} = adapter.update_message_external_id(state, "missing", "provider-id")
      assert :ok = adapter.delete_message(state, "missing")
      assert {:error, :not_found} = adapter.delete_room_binding(state, "missing")
      assert {:error, :not_found} = adapter.delete_bridge_config(state, "missing")
      assert {:error, :not_found} = adapter.delete_ingress_subscription(state, "bridge", "missing")
      assert {:error, :not_found} = adapter.delete_routing_policy(state, "missing")
      assert {:ok, ^room} = adapter.get_room(state, room.id)
      assert {:ok, ^person} = adapter.get_participant(state, person.id)
    end

    test "#{adapter} rebinding keeps the winning identity and rejects revoked scope" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      owner = Participant.new(%{id: "owner", type: :human})
      other = Participant.new(%{id: "other", type: :human})
      for person <- [owner, other], do: assert({:ok, person} == adapter.save_participant(state, person))
      assert :ok = adapter.bind_participant_external_id(state, owner.id, :slack, "bridge", "provider-user")
      assert :ok = adapter.bind_participant_external_id(state, owner.id, :slack, "bridge", "provider-user")

      assert {:error, {:external_identity_conflict, "owner"}} =
               adapter.bind_participant_external_id(state, other.id, :slack, "bridge", "provider-user")

      assert {:ok, binding} = adapter.get_external_identity_binding(state, :slack, "bridge", "provider-user")
      assert binding.participant_id == owner.id
      revoked = ExternalIdentityBinding.revoke(binding)
      assert {:ok, ^revoked} = adapter.save_external_identity_binding(state, revoked)

      assert {:error, :external_identity_revoked} =
               adapter.bind_participant_external_id(state, owner.id, :slack, "bridge", "provider-user")

      assert {:ok, ^revoked} = adapter.get_external_identity_binding(state, :slack, "bridge", "provider-user")
      for person <- [owner, other], do: assert({:ok, person} == adapter.get_participant(state, person.id))
      assert {:error, :not_found} = adapter.bind_participant_external_id(state, "missing", :slack, "bridge", "another")
    end

    test "#{adapter} stale identity recovery retains foreign binding and full canonical history" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      old = Participant.new(%{id: "old", type: :human})
      replacement = Participant.new(%{id: "replacement", type: :human})
      for person <- [old, replacement], do: assert({:ok, person} == adapter.save_participant(state, person))
      assert :ok = adapter.bind_participant_external_id(state, old.id, :slack, "owned", "same")
      assert :ok = adapter.bind_participant_external_id(state, replacement.id, :slack, "foreign", "same")
      {:ok, foreign} = adapter.get_external_identity_binding(state, :slack, "foreign", "same")
      room = Room.new(%{id: "history-room", type: :group})
      {:ok, ^room} = adapter.save_room(state, room)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: old.id,
          role: :user,
          content: [%{type: :text, text: "complete historical content"}]
        })

      {:ok, ^message} = adapter.save_message(state, message)
      assert :ok = adapter.delete_participant(state, old.id)
      assert :ok = adapter.bind_participant_external_id(state, replacement.id, :slack, "owned", "same")
      assert {:ok, new_binding} = adapter.get_external_identity_binding(state, :slack, "owned", "same")
      assert new_binding.participant_id == replacement.id
      assert {:ok, ^foreign} = adapter.get_external_identity_binding(state, :slack, "foreign", "same")
      assert {:ok, ^message} = adapter.get_message(state, message.id)
      assert {:ok, ^replacement} = adapter.get_participant(state, replacement.id)
    end

    test "#{adapter} deleting a threaded message clears only its indexes" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      for id <- ["owned", "foreign"] do
        {:ok, _} = adapter.save_room(state, Room.new(%{id: id, type: :group}))
        {:ok, _} = adapter.save_thread(state, Thread.new(%{id: id <> "-thread", room_id: id}))

        {:ok, _} =
          adapter.save_message(
            state,
            Message.new(%{
              id: id <> "-message",
              room_id: id,
              thread_id: id <> "-thread",
              sender_id: "sender",
              role: :user,
              content: [%{type: :text, text: id}]
            })
          )
      end

      {:ok, foreign} = adapter.get_message(state, "foreign-message")
      assert :ok = adapter.delete_message(state, "owned-message")
      assert {:ok, []} = adapter.get_messages(state, "owned")
      assert {:ok, []} = adapter.get_messages(state, "owned", thread_id: "owned-thread")
      assert {:ok, [^foreign]} = adapter.get_messages(state, "foreign", thread_id: "foreign-thread")
      assert :ok = adapter.delete_message(state, "owned-message")
    end
  end

  test "SQLite rejects a broken legacy schema and rolls back without losing its rows" do
    path = Path.join(System.tmp_dir!(), "checkpoint-migration-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(path) end)
    {:ok, db} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE jido_messaging_records (id TEXT PRIMARY KEY, payload TEXT)")
    :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO jido_messaging_records VALUES ('owned', 'complete')")
    :ok = Exqlite.Sqlite3.close(db)
    assert {:error, _} = Persistence.SQLite.init(path: path)
    {:ok, db} = Exqlite.Sqlite3.open(path)
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT id, payload FROM jido_messaging_records")
    assert {:ok, [["owned", "complete"]]} = Exqlite.Sqlite3.fetch_all(db, statement)
    :ok = Exqlite.Sqlite3.release(db, statement)
    :ok = Exqlite.Sqlite3.close(db)
  end
end
