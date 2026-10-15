defmodule Jido.Messaging.TranscriptPagingOwnershipTest do
  use ExUnit.Case, async: true

  defmodule ETSInstance do
    use Jido.Messaging, runtime_profile: :core
  end

  defmodule SQLiteInstance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite, runtime_profile: :core
  end

  defmodule Projection do
    @behaviour Jido.Messaging.SearchProjection
    def upsert(_entry, _context, _opts), do: :ok
    def delete(_id, _context, _opts), do: :ok
    def search(_query, _context, _opts), do: {:ok, []}

    def rebuild(entries, context, opts) do
      send(Keyword.fetch!(opts, :observer), {:rebuild, entries, context, opts})
      :ok
    end
  end

  setup do
    path = Path.join(System.tmp_dir!(), "transcript-page-#{System.unique_integer([:positive])}.sqlite3")
    start_supervised!(ETSInstance)
    start_supervised!({SQLiteInstance, persistence_opts: [path: path]})
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  for instance <- [ETSInstance, SQLiteInstance] do
    test "#{instance} invalid cursor and limit cannot cross participant or room scope" do
      instance = unquote(instance)
      context = seed(instance)

      for limit <- [0, -1, "2", nil],
          do:
            assert(
              {:error, :invalid_limit} ==
                instance.participant_transcript(context.participant.id, context.scope, limit: limit)
            )

      for opts <- [[before: ""], [after: 1], [before: "m-1", after: "m-2"]] do
        assert {:error, :invalid_cursor_options} =
                 instance.participant_transcript(context.participant.id, context.scope, opts)
      end

      for cursor <- ["missing", context.foreign_room_message.id, context.other_participant_message.id] do
        for direction <- [:before, :after] do
          assert {:error, :cursor_not_found} =
                   instance.participant_transcript(context.participant.id, context.scope, [{direction, cursor}])
        end
      end

      assert {:ok, entries} = instance.participant_transcript(context.participant.id, context.scope, limit: 2)
      assert Enum.map(entries, & &1.canonical_message_id) == ["m-4", "m-5"]

      assert {:ok, next} =
               instance.participant_transcript(context.participant.id, context.scope, after: "m-2", limit: 2)

      assert Enum.map(next, & &1.canonical_message_id) == ["m-3", "m-4"]

      assert {:ok, before} =
               instance.participant_transcript(context.participant.id, context.scope, before: "m-4", limit: 2)

      assert Enum.map(before, & &1.canonical_message_id) == ["m-2", "m-3"]
      assert {:error, :not_found} = instance.participant_transcript("missing-participant", context.scope)
    end

    test "#{instance} rebuild collects every allowed page exactly once in canonical order" do
      instance = unquote(instance)
      context = seed(instance)

      for batch_size <- [1, 2, 1001, :invalid] do
        assert :ok =
                 instance.rebuild_transcript_search(context.participant.id, context.scope,
                   projection: Projection,
                   observer: self(),
                   batch_size: batch_size,
                   before: "foreign-cursor",
                   after: "foreign-cursor"
                 )

        assert_received {:rebuild, entries, %{instance_module: ^instance, scope: scope}, opts}
        assert scope == context.scope
        assert Enum.map(entries, & &1.canonical_message_id) == Enum.map(context.allowed, & &1.id)
        assert Enum.map(entries, &(&1.message.content |> hd() |> Map.fetch!(:text))) == ~w(m-1 m-2 m-3 m-4 m-5)
        refute Keyword.has_key?(opts, :batch_size)
        refute Keyword.has_key?(opts, :projection)
      end
    end
  end

  defp seed(instance) do
    {:ok, room} = instance.create_room(%{id: "allowed", type: :group})
    {:ok, foreign} = instance.create_room(%{id: "foreign", type: :group})
    {:ok, participant} = instance.create_participant(%{id: "owned", type: :human})
    {:ok, other} = instance.create_participant(%{id: "other", type: :human})
    {:ok, scope} = instance.history_scope([room.id])
    allowed = for n <- 1..5, do: save(instance, room.id, participant.id, "m-#{n}", n)
    foreign_room_message = save(instance, foreign.id, participant.id, "foreign-message", 6)
    other_participant_message = save(instance, room.id, other.id, "other-message", 7)

    %{
      participant: participant,
      scope: scope,
      allowed: allowed,
      foreign_room_message: foreign_room_message,
      other_participant_message: other_participant_message
    }
  end

  defp save(instance, room, participant, id, n) do
    {:ok, message} =
      instance.save_message(%{
        id: id,
        room_id: room,
        sender_id: participant,
        role: :user,
        content: [Jido.Chat.Content.Text.new(id)],
        inserted_at: DateTime.add(~U[2026-10-13 05:00:00Z], n, :second)
      })

    message
  end
end
