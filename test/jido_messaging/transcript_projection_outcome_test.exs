defmodule Jido.Messaging.TranscriptProjectionOutcomeTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Persistence.ETS

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name not in [:get_participant_messages, :get_message] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def get_message(state, id) do
      if failure = Process.get(:canonical_message_failure), do: failure(failure), else: ETS.get_message(state, id)
    end

    def get_participant_messages(state, participant, rooms, opts) do
      send(self(), {:history_page, opts})

      if Keyword.has_key?(opts, :before) and Process.get(:history_page_failure) do
        failure(Process.get(:history_page_failure))
      else
        ETS.get_participant_messages(state, participant, rooms, opts)
      end
    end

    defp failure(:error), do: {:error, :history_unavailable}
    defp failure(:raise), do: raise("private history failure")
    defp failure(:throw), do: throw(:private_history_failure)
    defp failure(:exit), do: exit(:private_history_failure)
    defp failure(:invalid), do: :invalid
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Projection do
    @behaviour Jido.Messaging.SearchProjection
    def upsert(entry, context, opts), do: result(:upsert, entry, context, opts)
    def delete(id, context, opts), do: result(:delete, id, context, opts)
    def search(query, context, opts), do: result(:search, query, context, opts)
    def rebuild(entries, context, opts), do: result(:rebuild, entries, context, opts)

    defp result(operation, value, context, opts) do
      send(self(), {:projection_effect, operation, value, context})

      case opts[:failure] do
        :error -> {:error, :projection_unavailable}
        :raise -> raise "private projection failure"
        :throw -> throw(:private_projection_failure)
        :exit -> exit(:private_projection_failure)
        :invalid -> :invalid
        _ -> if(operation == :search, do: {:ok, Keyword.get(opts, :results, [])}, else: :ok)
      end
    end
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "allowed", type: :group})
    {:ok, person} = Instance.create_participant(%{id: "person", type: :human})

    messages =
      for n <- 1..3 do
        {:ok, message} =
          Instance.save_message(%{
            id: "m-#{n}",
            room_id: room.id,
            sender_id: person.id,
            role: :user,
            content: [Jido.Chat.Content.Text.new("complete #{n}")],
            inserted_at: DateTime.add(~U[2026-10-13 05:00:00Z], n, :second)
          })

        message
      end

    {:ok, scope} = Instance.history_scope([room.id])
    %{room: room, person: person, messages: messages, scope: scope}
  end

  for operation <- [:search, :upsert, :delete, :rebuild], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{operation} #{failure} projection failure returns safely without changing canonical messages", context do
      result = project(unquote(operation), context, failure: unquote(failure))
      expected = projection_error(unquote(failure))
      assert {:error, ^expected} = result
      assert_received {:projection_effect, unquote(operation), _, %{scope: scope}}
      assert scope == context.scope
      for message <- context.messages, do: assert({:ok, message} == Instance.get_message(message.id))
      assert project(unquote(operation), context, []) in [:ok, {:ok, []}]
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{failure} later canonical page cannot return a partial successful rebuild", context do
      Process.put(:history_page_failure, unquote(failure))
      expected = history_error(unquote(failure))
      assert {:error, ^expected} = project(:rebuild, context, batch_size: 1)
      refute_received {:projection_effect, :rebuild, _, _}
      assert_received {:history_page, first}
      assert first[:limit] == 1
      assert_received {:history_page, second}
      assert second[:before] == "m-3"
      Process.delete(:history_page_failure)
      assert :ok = project(:rebuild, context, batch_size: 1)
      assert_received {:projection_effect, :rebuild, entries, _}
      assert Enum.map(entries, & &1.canonical_message_id) == ~w(m-1 m-2 m-3)
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{failure} canonical upsert read rejects before projection effects", context do
      Process.put(:canonical_message_failure, unquote(failure))
      expected = history_error(unquote(failure))
      assert {:error, ^expected} = project(:upsert, context, [])
      refute_received {:projection_effect, :upsert, _, _}
      Process.delete(:canonical_message_failure)
      assert :ok = project(:upsert, context, [])
      assert_received {:projection_effect, :upsert, entry, _}
      assert entry.canonical_message_id == "m-1"
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{failure} canonical search validation cannot accept an unverifiable projected message", context do
      {:ok, [entry | _]} = Instance.participant_transcript(context.person.id, context.scope)
      Process.put(:canonical_message_failure, unquote(failure))
      assert {:error, :search_projection_scope_violation} = project(:search, context, results: [entry])
      assert_received {:projection_effect, :search, "query", _}
      Process.delete(:canonical_message_failure)
      assert {:ok, [^entry]} = project(:search, context, results: [entry])
    end
  end

  defp project(:search, context, opts),
    do: Instance.search_transcript("query", context.scope, Keyword.put(opts, :projection, Projection))

  defp project(:upsert, context, opts),
    do: Instance.upsert_transcript_search("m-1", context.scope, Keyword.put(opts, :projection, Projection))

  defp project(:delete, context, opts),
    do:
      Instance.delete_transcript_search(
        "m-1",
        context.room.id,
        context.scope,
        Keyword.put(opts, :projection, Projection)
      )

  defp project(:rebuild, context, opts),
    do: Instance.rebuild_transcript_search(context.person.id, context.scope, Keyword.put(opts, :projection, Projection))

  defp projection_error(:error), do: :projection_unavailable
  defp projection_error(:invalid), do: :invalid_search_projection_result
  defp projection_error(_failure), do: :search_projection_failed
  defp history_error(:error), do: :history_unavailable
  defp history_error(:invalid), do: :invalid_transcript_result
  defp history_error(_failure), do: :transcript_read_failed
end
