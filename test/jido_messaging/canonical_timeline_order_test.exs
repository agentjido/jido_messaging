defmodule Jido.Messaging.CanonicalTimelineOrderTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{Message, Persistence, Query, Runtime}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  defmodule ETSInstance do
    use Jido.Messaging, persistence: Persistence.ETS, runtime_profile: :core
  end

  defmodule SQLiteInstance do
    use Jido.Messaging, persistence: Persistence.SQLite, runtime_profile: :core
  end

  test "timeline accepts missing timestamps and orders equal instants by canonical ID" do
    [root, second, reply, orphan] = records()

    expected = %{
      messages: [root, second],
      threads: %{root.id => [reply], "missing-root" => [orphan]},
      reply_counts: %{root.id => 1, second.id => 0}
    }

    assert Query.room_timeline([orphan, second, reply, root]) == expected
    assert Query.room_timeline([second, root, orphan, reply]) == expected
    assert Query.room_timeline([]) == %{messages: [], threads: %{}, reply_counts: %{}}
  end

  test "equal timestamps preserve ID order across top-level and thread groups" do
    records = Enum.map(records(), &%{&1 | inserted_at: ~U[2026-08-20 12:00:00Z]})
    [root, second, reply, orphan] = records
    timeline = Query.room_timeline(Enum.reverse(records))
    assert timeline.messages == [root, second]
    assert timeline.threads == %{root.id => [reply], "missing-root" => [orphan]}
    assert timeline.reply_counts == %{root.id => 1, second.id => 0}
  end

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ] do
    @tag postgres: adapter == Persistence.Postgres
    test "#{adapter} complete canonical timeline and cursors retain timestamp-less records" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      records = records()
      [root, second, reply, orphan] = records
      foreign = %{root | id: "foreign", room_id: "foreign-room", content: [%{type: :text, text: "foreign complete"}]}
      for record <- Enum.reverse(records ++ [foreign]), do: assert({:ok, record} == adapter.save_message(state, record))
      assert {:ok, complete} = adapter.get_messages(state, "owned-room", limit: 10)
      assert complete == [root, reply, second, orphan]
      timeline = Query.room_timeline(complete)
      assert timeline.messages == [root, second]
      assert timeline.threads == %{root.id => [reply], "missing-root" => [orphan]}
      assert {:ok, [^root]} = adapter.get_messages(state, "owned-room", before: reply.id)
      assert {:ok, [^second, ^orphan]} = adapter.get_messages(state, "owned-room", after: reply.id)
      assert {:error, :cursor_not_found} = adapter.get_messages(state, "owned-room", before: foreign.id)
      for record <- records ++ [foreign], do: assert({:ok, record} == adapter.get_message(state, record.id))
    end
  end

  test "instance and root facade timelines preserve full owned records and no communication effects" do
    path = Path.join(System.tmp_dir!(), "canonical-timeline-#{System.unique_integer([:positive])}.sqlite3")
    start_supervised!(ETSInstance)
    start_supervised!({SQLiteInstance, persistence_opts: [path: path]})
    on_exit(fn -> File.rm(path) end)

    for instance <- [ETSInstance, SQLiteInstance] do
      runtime = instance.__jido_messaging__(:runtime)
      {:ok, _} = instance.create_room(%{id: "owned-room", type: :group})
      for record <- records(), do: assert({:ok, record} == instance.save_message_struct(record))
      assert {:ok, timeline} = instance.room_timeline("owned-room")
      assert {:ok, ^timeline} = Jido.Messaging.room_timeline(runtime, "owned-room")
      [root, second, reply, orphan] = records()
      assert timeline.messages == [root, second]
      assert timeline.threads == %{root.id => [reply], "missing-root" => [orphan]}
      assert {:error, :cursor_not_found} = instance.room_timeline("owned-room", before: "missing")
      assert :ets.info(Runtime.request_table(runtime), :size) == 0
      assert instance.count_agents() == 0
      assert {:ok, []} = instance.list_memberships("owned-room")
      assert {:ok, []} = instance.list_principal_grants("sender")
      for record <- records(), do: assert({:ok, record} == instance.get_message(record.id))
    end
  end

  defp records do
    base = %{
      room_id: "owned-room",
      sender_id: "sender",
      role: :user,
      status: :sent,
      updated_at: nil,
      metadata: %{complete: "metadata"},
      content: [%{type: :text, text: "complete content"}, %{type: :image, url: "https://example.test/image"}]
    }

    [
      Message.new(Map.merge(base, %{id: "a-root", inserted_at: nil})),
      Message.new(Map.merge(base, %{id: "b-root", inserted_at: ~U[2026-08-20 12:00:00Z]})),
      Message.new(Map.merge(base, %{id: "c-reply", inserted_at: nil, thread_id: "a-root", reply_to_id: "a-root"})),
      Message.new(Map.merge(base, %{id: "d-orphan", inserted_at: ~U[2026-08-20 12:00:00Z], thread_id: "missing-root"}))
    ]
  end
end
