defmodule Jido.Messaging.Persistence.StoredRecordCompatibilityTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.Persistence.{Payload, Postgres, SQLite}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  @fixture Path.expand("../../fixtures/stored_records_v1.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  for {name, fixture} <- @fixture["records"] do
    test "#{name} reads and writes the pre-C4 term with the same fields and values" do
      module = ("Elixir." <> unquote(name)) |> String.to_existing_atom()
      Code.ensure_loaded!(module)
      payload = Base.decode64!(unquote(fixture["payload"]))
      record = Payload.decode(payload)
      assert record.__struct__ == module

      if Map.has_key?(record, :metadata) do
        assert record.metadata == %{legacy: true, nested: %{"text" => "unchanged"}}
      end

      assert Payload.decode(payload, [:safe]) == record
      assert Payload.decode(Payload.encode(record), [:safe]) == record

      fields = struct(module) |> Map.from_struct() |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      assert fields == unquote(fixture["fields"])
    end
  end

  for {adapter, start, stop} <- [
        {SQLite, :start_sqlite, :stop_sqlite},
        {Postgres, :start_postgres, :stop_postgres}
      ] do
    if adapter == Postgres, do: @tag(:postgres)

    test "#{adapter} reopens old payloads and keeps public reads and message order", %{} do
      adapter = unquote(adapter)
      {:ok, initial} = apply(Factory, unquote(start), [])
      on_exit(:stored_records, fn -> apply(Factory, unquote(stop), [initial]) end)

      records = [
        {"room", Jido.Chat.Room, :get_room},
        {"participant", Jido.Chat.Participant, :get_participant},
        {"message", Jido.Messaging.Message, :get_message},
        {"thread", Jido.Messaging.Thread, :get_thread},
        {"principal", Jido.Messaging.Principal, :get_principal},
        {"membership", Jido.Messaging.Membership, :get_membership},
        {"principal_grant", Jido.Messaging.Grant, :get_principal_grant},
        {"invocation_policy", Jido.Messaging.InvocationPolicy, :get_invocation_policy}
      ]

      stored =
        for {kind, module, getter} <- records do
          Code.ensure_loaded!(module)
          payload = Base.decode64!(@fixture["records"][inspect(module)]["payload"])
          record = Payload.decode(payload)
          insert_old_payload(adapter, initial, kind, record, payload)
          assert {:ok, ^record} = apply(adapter, getter, [initial, record.id])
          {getter, record, payload}
        end

      :ok = adapter.close(initial)

      {:ok, reopened} = reopen(adapter, initial)
      on_exit(:stored_records, fn -> apply(Factory, unquote(stop), [reopened]) end)

      for {getter, record, payload} <- stored do
        assert {:ok, ^record} = apply(adapter, getter, [reopened, record.id])
        assert fetch_payload(adapter, reopened, record.id, getter) == payload
      end

      message = Enum.find_value(stored, fn {getter, record, _} -> if getter == :get_message, do: record end)
      assert {:ok, [^message]} = adapter.get_messages(reopened, message.room_id)
      assert {:error, :cursor_not_found} = adapter.get_messages(reopened, message.room_id, before: "missing")
      assert {:ok, []} = adapter.get_messages(reopened, message.room_id, before: message.id)
    end
  end

  defp reopen(SQLite, initial), do: SQLite.init(path: initial.path, instance_id: initial.instance_id)

  defp reopen(Postgres, initial) do
    with {:ok, state} <-
           Postgres.init(url: System.fetch_env!("JIDO_MESSAGING_POSTGRES_URL"), instance_id: initial.instance_id) do
      Process.unlink(state.pool)
      {:ok, state}
    end
  end

  defp insert_old_payload(SQLite, state, kind, record, payload) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(state.db, """
      INSERT INTO jido_messaging_records
        (instance_id, kind, id, room_id, sender_id, inserted_at, payload)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """)

    try do
      :ok = Exqlite.Sqlite3.bind(statement, old_columns(state, kind, record) ++ [{:blob, payload}])
      :done = Exqlite.Sqlite3.step(state.db, statement)
    after
      Exqlite.Sqlite3.release(state.db, statement)
    end
  end

  defp insert_old_payload(Postgres, state, kind, record, payload) do
    {:ok, _} =
      Postgrex.query(
        state.conn,
        """
        INSERT INTO jido_messaging_records
          (instance_id, kind, id, room_id, sender_id, inserted_at, payload)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        """,
        old_columns(state, kind, record) ++ [payload]
      )
  end

  defp old_columns(state, kind, record) do
    [
      state.instance_id,
      kind,
      record.id,
      Map.get(record, :room_id),
      Map.get(record, :sender_id),
      old_timestamp(Map.get(record, :inserted_at))
    ]
  end

  defp old_timestamp(nil), do: nil
  defp old_timestamp(value), do: Jido.Messaging.Transcript.format_timestamp(value)

  defp fetch_payload(SQLite, state, id, getter) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(
        state.db,
        "SELECT payload FROM jido_messaging_records WHERE instance_id = ?1 AND kind = ?2 AND id = ?3"
      )

    try do
      :ok = Exqlite.Sqlite3.bind(statement, [state.instance_id, kind(getter), id])
      {:row, [payload]} = Exqlite.Sqlite3.step(state.db, statement)
      payload
    after
      Exqlite.Sqlite3.release(state.db, statement)
    end
  end

  defp fetch_payload(Postgres, state, id, getter) do
    {:ok, %{rows: [[payload]]}} =
      Postgrex.query(
        state.conn,
        "SELECT payload FROM jido_messaging_records WHERE instance_id = $1 AND kind = $2 AND id = $3",
        [state.instance_id, kind(getter), id]
      )

    payload
  end

  defp kind(:get_room), do: "room"
  defp kind(:get_participant), do: "participant"
  defp kind(:get_message), do: "message"
  defp kind(:get_thread), do: "thread"
  defp kind(:get_principal), do: "principal"
  defp kind(:get_membership), do: "membership"
  defp kind(:get_principal_grant), do: "principal_grant"
  defp kind(:get_invocation_policy), do: "invocation_policy"
end
