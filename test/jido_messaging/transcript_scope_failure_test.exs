defmodule Jido.Messaging.TranscriptScopeFailureTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{HistoryScope, Runtime}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  defmodule Projection do
    @behaviour Jido.Messaging.SearchProjection
    def upsert(entry, context, opts), do: response(:upsert, entry, context, opts)
    def delete(id, context, opts), do: response(:delete, id, context, opts)
    def search(query, context, opts), do: response(:search, query, context, opts)
    def rebuild(entries, context, opts), do: response(:rebuild, entries, context, opts)

    defp response(operation, value, context, opts) do
      send(Keyword.fetch!(opts, :observer), {:projection_call, operation, value, context})
      Keyword.get(opts, :response, if(operation == :search, do: {:ok, []}, else: :ok))
    end
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "allowed", type: :group})
    {:ok, participant} = Instance.create_participant(%{id: "participant", type: :human})
    {:ok, scope} = Instance.history_scope([room.id])
    %{room: room, participant: participant, scope: scope}
  end

  for rooms <- [[nil], [""], [1], [%{id: "allowed"}], :invalid] do
    test "invalid manually constructed room scope #{inspect(rooms)} rejects before projection admission", context do
      scope = %HistoryScope{instance_module: Instance, room_ids: unquote(Macro.escape(rooms))}

      assert {:error, :invalid_history_scope} =
               Instance.search_transcript("query", scope, projection: Projection, observer: self())

      refute_received {:projection_call, _, _, _}
      assert {:error, :invalid_history_scope} = Instance.participant_transcript(context.participant.id, scope)

      assert {:error, :invalid_history_scope} =
               Instance.upsert_transcript_search("missing", scope, projection: Projection, observer: self())

      assert {:error, :invalid_history_scope} =
               Instance.delete_transcript_search("missing", context.room.id, scope,
                 projection: Projection,
                 observer: self()
               )

      assert {:error, :invalid_history_scope} =
               Instance.rebuild_transcript_search(context.participant.id, scope,
                 projection: Projection,
                 observer: self()
               )

      refute_received {:projection_call, _, _, _}
    end
  end

  test "manually constructed metadata must retain a plain history scope map", context do
    scope = %{context.scope | metadata: :invalid}
    assert {:error, :invalid_history_scope} = Instance.participant_transcript(context.participant.id, scope)

    assert {:error, :invalid_history_scope} =
             Instance.search_transcript("query", scope, projection: Projection, observer: self())

    refute_received {:projection_call, _, _, _}
  end

  test "empty scope and unknown projection cannot admit work or infer history", context do
    {:ok, empty} = Instance.history_scope([])
    assert {:ok, []} = Instance.participant_transcript(context.participant.id, empty)

    assert :ok =
             Instance.rebuild_transcript_search(context.participant.id, empty,
               projection: Projection,
               observer: self(),
               batch_size: :invalid
             )

    assert_received {:projection_call, :rebuild, [], %{scope: ^empty}}

    assert {:error, :invalid_search_projection} =
             Instance.search_transcript("query", context.scope, projection: __MODULE__)

    assert {:error, :search_projection_not_configured} =
             Instance.search_transcript("query", context.scope, projection: 1)

    refute_received {:projection_call, _, _, _}
  end

  test "invalid projection result and provider error leave canonical records and authority unchanged", context do
    assert {:error, :invalid_search_projection_result} =
             Instance.search_transcript("query", context.scope,
               projection: Projection,
               observer: self(),
               response: {:ok, :invalid}
             )

    assert_received {:projection_call, :search, "query", %{scope: scope}}
    assert scope == context.scope

    assert {:error, :projection_unavailable} =
             Instance.search_transcript("query", context.scope,
               projection: Projection,
               observer: self(),
               response: {:error, :projection_unavailable}
             )

    assert_received {:projection_call, :search, "query", _}
    assert {:ok, []} = Instance.list_messages(context.room.id)
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    assert :ets.info(state.principal_grants, :size) == 0
    assert :ets.info(state.memberships, :size) == 0
  end
end
