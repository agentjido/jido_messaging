defmodule Jido.Messaging.ParticipantTranscriptTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.TranscriptEntry

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule Projection do
    @behaviour Jido.Messaging.SearchProjection

    @impl true
    def upsert(_entry, _context, _opts), do: :ok

    @impl true
    def delete(_message_id, _context, _opts), do: :ok

    @impl true
    def search(query, context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:projection_search, query, context})
      {:ok, Keyword.get(opts, :results, [])}
    end

    @impl true
    def rebuild(entries, context, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:projection_rebuild, entries, context})
      :ok
    end
  end

  setup do
    path = Path.join(System.tmp_dir!(), "jido-messaging-transcript-#{System.unique_integer([:positive])}.sqlite3")
    File.rm(path)

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "ETS and SQLite return the same scoped participant transcript" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      records = seed_transcript(messaging)
      assert {:ok, scope} = messaging.history_scope([records.room_one.id, records.room_two.id])

      assert {:ok, entries} = messaging.participant_transcript(records.participant.id, scope, limit: 10)

      assert Enum.map(entries, & &1.canonical_message_id) ==
               Enum.map(records.allowed_messages, & &1.id)

      assert Enum.all?(entries, &match?(%TranscriptEntry{}, &1))
      assert Enum.all?(entries, &(&1.instance_module == messaging))
      refute Enum.any?(entries, &(&1.room_id == records.denied_room.id))

      [slack_entry, telegram_entry, _slack_entry] = entries
      assert slack_entry.canonical_participant_id == records.participant.id
      assert slack_entry.provider_participant_id == "U-provider"
      assert slack_entry.provider_message_id == "slack-message-1"
      assert slack_entry.channel == :slack
      assert slack_entry.bridge_id == "slack-main"
      assert telegram_entry.provider_participant_id == "T-provider"
      assert telegram_entry.provider_message_id == "telegram-message-1"

      assert {:ok, after_page} =
               messaging.participant_transcript(records.participant.id, scope,
                 after: List.first(records.allowed_messages).id,
                 limit: 10
               )

      assert Enum.map(after_page, & &1.canonical_message_id) ==
               records.allowed_messages |> Enum.drop(1) |> Enum.map(& &1.id)

      assert {:ok, before_page} =
               messaging.participant_transcript(records.participant.id, scope,
                 before: List.last(records.allowed_messages).id,
                 limit: 10
               )

      assert Enum.map(before_page, & &1.canonical_message_id) ==
               records.allowed_messages |> Enum.drop(-1) |> Enum.map(& &1.id)

      assert {:error, :cursor_not_found} =
               messaging.participant_transcript(records.participant.id, scope,
                 before: records.denied_message.id,
                 limit: 10
               )
    end
  end

  test "history scope is mandatory and bound to one instance" do
    records = seed_transcript(ETSMessaging)
    assert {:ok, ets_scope} = ETSMessaging.history_scope([records.room_one.id])

    assert {:error, :history_scope_required} =
             ETSMessaging.participant_transcript(records.participant.id, %{room_ids: [records.room_one.id]})

    assert {:error, :history_scope_instance_mismatch} =
             SQLiteMessaging.participant_transcript(records.participant.id, ets_scope)
  end

  test "optional projection receives mandatory scope and can rebuild from canonical history" do
    records = seed_transcript(ETSMessaging)
    assert {:ok, scope} = ETSMessaging.history_scope([records.room_one.id, records.room_two.id])

    assert {:error, :search_projection_not_configured} =
             ETSMessaging.search_transcript("hello", scope)

    assert {:ok, []} =
             ETSMessaging.search_transcript("hello", scope,
               projection: Projection,
               test_pid: self()
             )

    assert_receive {:projection_search, "hello", %{instance_module: ETSMessaging, scope: ^scope}}

    assert {:ok, [entry | _entries]} =
             ETSMessaging.participant_transcript(records.participant.id, scope, limit: 10)

    leaked_entry = %{entry | room_id: records.denied_room.id}

    assert {:error, :search_projection_scope_violation} =
             ETSMessaging.search_transcript("leak", scope,
               projection: Projection,
               test_pid: self(),
               results: [leaked_entry]
             )

    nested_room_leak = %{entry | message: %{entry.message | room_id: records.denied_room.id}}

    assert {:error, :search_projection_scope_violation} =
             ETSMessaging.search_transcript("nested leak", scope,
               projection: Projection,
               test_pid: self(),
               results: [nested_room_leak]
             )

    mismatched_id = %{entry | message: %{entry.message | id: "different-message"}}

    assert {:error, :search_projection_scope_violation} =
             ETSMessaging.search_transcript("mismatched id", scope,
               projection: Projection,
               test_pid: self(),
               results: [mismatched_id]
             )

    assert :ok =
             ETSMessaging.rebuild_transcript_search(records.participant.id, scope,
               projection: Projection,
               batch_size: 2,
               test_pid: self()
             )

    assert_receive {:projection_rebuild, entries, %{instance_module: ETSMessaging, scope: ^scope}}
    assert Enum.map(entries, & &1.canonical_message_id) == Enum.map(records.allowed_messages, & &1.id)
  end

  test "ETS and SQLite paginate messages with nullable timestamps" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = messaging |> Module.split() |> List.last() |> String.downcase()
      {:ok, room} = messaging.create_room(%{id: "#{prefix}-nullable-room", type: :group})

      {:ok, participant} =
        messaging.create_participant(%{
          id: "#{prefix}-nullable-participant",
          type: :human,
          identity: %{name: "Nullable User"}
        })

      without_timestamp =
        save_message(
          messaging,
          participant.id,
          room.id,
          "#{prefix}-nullable-message",
          nil,
          :slack,
          "slack-main",
          "nullable-provider-message"
        )

      with_timestamp =
        save_message(
          messaging,
          participant.id,
          room.id,
          "#{prefix}-dated-message",
          DateTime.from_unix!(1_700_000_000),
          :slack,
          "slack-main",
          "dated-provider-message"
        )

      assert {:ok, scope} = messaging.history_scope([room.id])
      assert {:ok, entries} = messaging.participant_transcript(participant.id, scope, limit: 10)

      assert Enum.map(entries, & &1.canonical_message_id) == [without_timestamp.id, with_timestamp.id]

      assert {:ok, [before_entry]} =
               messaging.participant_transcript(participant.id, scope,
                 before: with_timestamp.id,
                 limit: 10
               )

      assert before_entry.canonical_message_id == without_timestamp.id
    end
  end

  defp seed_transcript(messaging) do
    prefix = messaging |> Module.split() |> List.last() |> String.downcase()

    {:ok, room_one} = messaging.create_room(%{id: "#{prefix}-room-1", type: :group})
    {:ok, room_two} = messaging.create_room(%{id: "#{prefix}-room-2", type: :group})
    {:ok, denied_room} = messaging.create_room(%{id: "#{prefix}-room-denied", type: :group})

    {:ok, participant} =
      messaging.create_participant(%{
        id: "#{prefix}-participant",
        type: :human,
        identity: %{name: "Linked person"},
        external_ids: %{slack: "U-provider", telegram: "T-provider"}
      })

    {:ok, other_participant} =
      messaging.create_participant(%{
        id: "#{prefix}-other-participant",
        type: :human,
        identity: %{name: "Other person"}
      })

    base = DateTime.from_unix!(1_700_000_000)

    allowed_messages = [
      save_message(
        messaging,
        participant.id,
        room_one.id,
        "#{prefix}-message-1",
        base,
        :slack,
        "slack-main",
        "slack-message-1"
      ),
      save_message(
        messaging,
        participant.id,
        room_two.id,
        "#{prefix}-message-2",
        DateTime.add(base, 1, :second),
        :telegram,
        "telegram-main",
        "telegram-message-1"
      ),
      save_message(
        messaging,
        participant.id,
        room_one.id,
        "#{prefix}-message-3",
        DateTime.add(base, 2, :second),
        :slack,
        "slack-main",
        "slack-message-2"
      )
    ]

    denied_message =
      save_message(
        messaging,
        participant.id,
        denied_room.id,
        "#{prefix}-message-denied",
        DateTime.add(base, 3, :second),
        :slack,
        "slack-main",
        "slack-message-denied"
      )

    _other_message =
      save_message(
        messaging,
        other_participant.id,
        room_one.id,
        "#{prefix}-message-other",
        DateTime.add(base, 4, :second),
        :slack,
        "slack-main",
        "slack-message-other"
      )

    %{
      room_one: room_one,
      room_two: room_two,
      denied_room: denied_room,
      participant: participant,
      allowed_messages: allowed_messages,
      denied_message: denied_message
    }
  end

  defp save_message(messaging, participant_id, room_id, id, inserted_at, channel, bridge_id, external_id) do
    {:ok, message} =
      messaging.save_message(%{
        id: id,
        room_id: room_id,
        sender_id: participant_id,
        role: :user,
        content: [%{type: :text, text: id}],
        external_id: external_id,
        inserted_at: inserted_at,
        metadata: %{channel: channel, bridge_id: bridge_id}
      })

    message
  end
end
