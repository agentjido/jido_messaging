defmodule Jido.Messaging.Persistence.DirectoryLimitOrderTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.Persistence
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ] do
    for target <- [:participant, :room] do
      @tag postgres: adapter == Persistence.Postgres
      test "#{adapter} #{target} limit applies after complete matching and ID ordering" do
        adapter = unquote(adapter)
        target = unquote(target)
        {:ok, state} = apply(Factory, unquote(factory), [])
        on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

        records =
          for {id, name} <- [{"z-match", "Matching last"}, {"a-other", "Unrelated"}, {"b-match", "Matching first"}] do
            record = record(target, id, name)
            assert {:ok, ^record} = save(adapter, state, target, record)
            record
          end

        [last, other, first] = records

        assert {:ok, [^first]} = adapter.directory_search(state, target, %{name: "MATCHING"}, limit: 1)
        assert {:ok, [^first, ^last]} = adapter.directory_search(state, target, %{name: "matching"}, limit: 2)
        assert {:ok, [^last]} = adapter.directory_search(state, target, %{id: last.id}, limit: 1)

        assert {:error, {:ambiguous, [^first, ^last]}} =
                 adapter.directory_lookup(state, target, %{name: "matching"}, limit: 1)

        assert {:ok, [^other]} = adapter.directory_search(state, target, %{id: other.id}, [])
        for stored <- records, do: assert({:ok, stored} == get(adapter, state, target, stored.id))
      end

      @tag postgres: adapter == Persistence.Postgres
      test "#{adapter} #{target} matching beyond the first 500 records remains complete" do
        adapter = unquote(adapter)
        target = unquote(target)
        {:ok, state} = apply(Factory, unquote(factory), [])
        on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

        records =
          for n <- 1..501 do
            item = record(target, "a-" <> String.pad_leading(Integer.to_string(n), 3, "0"), "Unrelated")
            assert {:ok, ^item} = save(adapter, state, target, item)
            item
          end

        wanted = record(target, "z-wanted", "Complete wanted")
        assert {:ok, ^wanted} = save(adapter, state, target, wanted)
        assert {:ok, [^wanted]} = adapter.directory_search(state, target, %{id: wanted.id}, limit: 1)
        assert {:ok, ^wanted} = adapter.directory_lookup(state, target, %{id: wanted.id}, [])
        assert {:ok, ^wanted} = get(adapter, state, target, wanted.id)
        assert {:ok, complete} = adapter.directory_search(state, target, %{}, limit: 502)
        assert complete == records ++ [wanted]
        assert {:ok, []} = adapter.directory_search(state, target, %{name: "absent"}, limit: 1)
        assert {:ok, []} = adapter.directory_search(state, target, %{}, limit: 0)

        for invalid <- [-1, nil, "1", 1.0] do
          assert {:error, :invalid_directory_limit} = adapter.directory_search(state, target, %{}, limit: invalid)
        end

        assert {:ok, ^wanted} = get(adapter, state, target, wanted.id)
      end
    end
  end

  defp record(:participant, id, name), do: Participant.new(%{id: id, type: :human, identity: %{name: name}})
  defp record(:room, id, name), do: Room.new(%{id: id, type: :group, name: name})
  defp save(adapter, state, :participant, record), do: adapter.save_participant(state, record)
  defp save(adapter, state, :room, record), do: adapter.save_room(state, record)
  defp get(adapter, state, :participant, id), do: adapter.get_participant(state, id)
  defp get(adapter, state, :room, id), do: adapter.get_room(state, id)
end
