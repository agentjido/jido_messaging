defmodule Jido.Messaging.Persistence.MessageQueryLimitScopeTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{Message, Persistence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ] do
    @tag postgres: adapter == Persistence.Postgres
    test "#{adapter} invalid limits return the defined error and keep complete records" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      records = seed(adapter, state)

      for limit <- [0, -1, nil, "1", 1.5, true],
          opts <- [[limit: limit], [limit: limit, thread_id: "shared-thread"], [limit: limit, before: "b"]] do
        assert {:error, :invalid_limit} = adapter.get_messages(state, "owned", opts)
        assert_records(adapter, state, records)
      end
    end

    @tag postgres: adapter == Persistence.Postgres
    test "#{adapter} limit and cursor selection preserve room and thread ownership" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      [first, second, third, foreign] = records = seed(adapter, state)
      assert {:ok, [^second, ^third]} = adapter.get_messages(state, "owned", limit: 2)
      assert {:ok, [^third]} = adapter.get_messages(state, "owned", thread_id: "shared-thread", limit: 1)
      assert {:ok, [^first, ^second]} = adapter.get_messages(state, "owned", before: third.id, limit: 2)
      assert {:ok, [^third]} = adapter.get_messages(state, "owned", after: second.id, limit: 1)
      assert {:ok, [^first]} = adapter.get_messages(state, "owned", thread_id: "shared-thread", before: third.id)
      assert {:error, :cursor_not_found} = adapter.get_messages(state, "owned", before: foreign.id)

      assert {:error, :cursor_not_found} =
               adapter.get_messages(state, "owned", thread_id: "shared-thread", after: second.id)

      for opts <- [[before: ""], [after: 1], [before: first.id, after: third.id]],
          do: assert({:error, :invalid_cursor_options} == adapter.get_messages(state, "owned", opts))

      assert {:ok, [^first, ^second, ^third]} = adapter.get_messages(state, "owned")
      assert_records(adapter, state, records)
    end
  end

  defp seed(adapter, state) do
    for {id, room, thread, time} <- [
          {"a", "owned", "shared-thread", nil},
          {"b", "owned", nil, ~U[2026-08-20 12:00:00Z]},
          {"c", "owned", "shared-thread", ~U[2026-08-20 12:00:00Z]},
          {"foreign", "foreign", "shared-thread", ~U[2026-08-20 12:00:00Z]}
        ] do
      message =
        Message.new(%{
          id: id,
          room_id: room,
          thread_id: thread,
          sender_id: "sender",
          role: :user,
          content: [%{type: :text, text: "Complete " <> id}, %{type: :image, url: "https://example.test/" <> id}],
          metadata: %{complete: id},
          inserted_at: time
        })

      assert {:ok, ^message} = adapter.save_message(state, message)
      message
    end
  end

  defp assert_records(adapter, state, records),
    do: Enum.each(records, fn original -> assert({:ok, original} == adapter.get_message(state, original.id)) end)
end
