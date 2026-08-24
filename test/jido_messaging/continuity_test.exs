defmodule Jido.Messaging.ContinuityTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Content.Text
  alias Jido.Messaging.{JidokaContinuityContext, JidokaContinuityRef, ThreadContinuityLink}

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule RestartMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  setup do
    path = sqlite_path("continuity")
    cleanup_sqlite(path)

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    on_exit(fn -> cleanup_sqlite(path) end)
    :ok
  end

  test "ETS and SQLite return only the scoped canonical thread context" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "context")
      attrs = continuity_attrs(records, "session-context")

      assert {:ok, %ThreadContinuityLink{} = link} = messaging.put_thread_continuity(attrs)
      assert link.principal_id == records.agent.id
      assert link.continuity_ref.jidoka_agent_ref == %{"system" => "jidoka", "id" => "support-agent"}

      assert {:ok, scope} = messaging.history_scope([records.room.id])
      assert {:ok, ^link} = messaging.get_thread_continuity(records.thread.id, scope)

      assert {:ok, %JidokaContinuityRef{} = reference} =
               messaging.resolve_thread_continuity(records.thread.id, scope)

      assert reference.session_id == "session-context"

      assert {:ok, %JidokaContinuityContext{} = context} =
               messaging.jidoka_continuity_context(records.thread.id, scope, limit: 20)

      assert context.link == link
      assert Enum.map(context.messages, & &1.id) == Enum.map(records.thread_messages, & &1.id)
      refute Enum.any?(context.messages, &(&1.id == records.room_message.id))
      refute Enum.any?(context.messages, &(&1.id == records.cross_room_message.id))
      refute Map.has_key?(Map.from_struct(context), :prompt)
      refute Map.has_key?(Map.from_struct(context), :memory)
      refute Map.has_key?(Map.from_struct(reference), :session_data)
    end
  end

  test "scope is mandatory, instance-bound, and checked before transcript access" do
    records = seed(ETSMessaging, "scope")
    assert {:ok, _link} = ETSMessaging.put_thread_continuity(continuity_attrs(records, "session-scope"))
    assert {:ok, allowed_scope} = ETSMessaging.history_scope([records.room.id])
    assert {:ok, denied_scope} = ETSMessaging.history_scope([records.other_room.id])

    assert {:error, :history_scope_required} =
             ETSMessaging.jidoka_continuity_context(records.thread.id, %{room_ids: [records.room.id]})

    assert {:error, :history_scope_instance_mismatch} =
             SQLiteMessaging.get_thread_continuity(records.thread.id, allowed_scope)

    assert {:error, :history_scope_violation} =
             ETSMessaging.jidoka_continuity_context(records.thread.id, denied_scope, before: records.room_message.id)

    assert {:error, :cursor_not_found} =
             ETSMessaging.jidoka_continuity_context(records.thread.id, allowed_scope, before: records.room_message.id)
  end

  test "the boundary rejects state payloads, non-Jidoka agents, and human principals" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "strict")
      attrs = continuity_attrs(records, "session-strict")

      assert {:ok, _link} = messaging.put_thread_continuity(attrs)

      assert {:error, :continuity_revision_conflict} =
               messaging.set_thread_continuity_status(records.thread.id, :unavailable, 2)

      assert {:error, :invalid_continuity_status_change} =
               messaging.set_thread_continuity_status(records.thread.id, :unknown, 1)

      assert {:error, :invalid_continuity_status_change} =
               messaging.set_thread_continuity_status(records.thread.id, :unavailable, 1, private_state: "not allowed")

      assert {:error, :invalid_thread_continuity_link} =
               messaging.put_thread_continuity(Map.put(attrs, :memory, [%{private: true}]))

      assert {:error, :invalid_thread_continuity_link} =
               messaging.put_thread_continuity(put_in(attrs, [:continuity_ref, :prompt], "private prompt"))

      assert {:error, :invalid_thread_continuity_link} =
               messaging.put_thread_continuity(
                 put_in(attrs, [:continuity_ref, :jidoka_agent_ref], %{system: :jido, id: "agent"})
               )

      human_attrs = %{attrs | principal_id: records.human.id}
      assert {:error, :continuity_principal_not_agent} = messaging.put_thread_continuity(human_attrs)
    end
  end

  test "link IDs keep room and thread boundaries unambiguous" do
    now = DateTime.utc_now()

    base = %{
      principal_id: "agent",
      continuity_ref: %{
        integration_id: "jidoka",
        jidoka_agent_ref: %{system: :jidoka, id: "agent"},
        session_id: "session"
      },
      source_revision: 1,
      source_updated_at: now
    }

    first = ThreadContinuityLink.new(Map.merge(base, %{room_id: "a:b", thread_id: "c"}))
    second = ThreadContinuityLink.new(Map.merge(base, %{room_id: "a", thread_id: "b:c"}))

    refute first.id == second.id
  end

  test "revision rules are idempotent and reject conflict, gap, and stale writes" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "revision")
      attrs = continuity_attrs(records, "session-revision")

      assert {:ok, first} = messaging.put_thread_continuity(attrs)
      assert {:ok, ^first} = messaging.put_thread_continuity(attrs)

      conflict = put_in(attrs, [:continuity_ref, :request_id], "request-conflict")
      assert {:error, :continuity_revision_conflict} = messaging.put_thread_continuity(conflict)

      gap = %{attrs | source_revision: 3}
      assert {:error, :continuity_revision_gap} = messaging.put_thread_continuity(gap)

      second =
        attrs
        |> put_in([:continuity_ref, :request_id], "request-2")
        |> Map.put(:source_revision, 2)
        |> Map.put(:source_updated_at, DateTime.add(attrs.source_updated_at, 1, :second))

      assert {:ok, %{source_revision: 2}} = messaging.put_thread_continuity(second)
      assert {:error, :continuity_stale_revision} = messaging.put_thread_continuity(attrs)
    end
  end

  test "agent or session replacement requires an opaque transition reference" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "replacement")
      attrs = continuity_attrs(records, "session-old")
      assert {:ok, first} = messaging.put_thread_continuity(attrs)

      replacement =
        attrs
        |> put_in([:continuity_ref, :session_id], "session-new")
        |> put_in([:continuity_ref, :jidoka_agent_ref, :id], "replacement-agent")
        |> Map.put(:source_revision, 2)
        |> Map.put(:source_updated_at, DateTime.add(attrs.source_updated_at, 1, :second))

      assert {:error, :continuity_transition_ref_required} =
               messaging.put_thread_continuity(replacement)

      assert {:ok, updated} =
               messaging.put_thread_continuity(Map.put(replacement, :transition_ref, "jidoka-handoff-42"))

      assert updated.id == first.id
      assert updated.inserted_at == first.inserted_at
      assert updated.transition_ref == "jidoka-handoff-42"
      assert updated.continuity_ref.session_id == "session-new"
    end
  end

  test "one live Jidoka session cannot be bound to two messaging threads" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "session-conflict")
      second_thread = create_thread!(messaging, records.other_room.id, "conflict-second")

      assert {:ok, _link} =
               messaging.put_thread_continuity(continuity_attrs(records, "shared-session"))

      second_attrs =
        continuity_attrs(
          %{records | room: records.other_room, thread: second_thread},
          "shared-session"
        )

      assert {:error, {:continuity_session_scope_conflict, existing_thread_id}} =
               messaging.put_thread_continuity(second_attrs)

      assert existing_thread_id == records.thread.id
    end
  end

  test "status errors are distinct and terminal links clear short references" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "status")
      attrs = continuity_attrs(records, "session-status")
      assert {:ok, _link} = messaging.put_thread_continuity(attrs)
      assert {:ok, scope} = messaging.history_scope([records.room.id])

      assert {:ok, _closed} =
               messaging.save_thread_struct(%{records.thread | status: :closed})

      assert {:error, {:continuity_thread_not_active, :closed}} =
               messaging.resolve_thread_continuity(records.thread.id, scope)

      assert {:ok, _active_thread} =
               messaging.save_thread_struct(%{records.thread | status: :active})

      assert {:ok, unavailable} =
               messaging.set_thread_continuity_status(
                 records.thread.id,
                 :unavailable,
                 1,
                 reason_code: "jidoka_store_offline"
               )

      assert unavailable.source_revision == 2

      assert {:error, {:continuity_unavailable, "jidoka_store_offline"}} =
               messaging.resolve_thread_continuity(records.thread.id, scope)

      assert {:ok, active} =
               messaging.set_thread_continuity_status(records.thread.id, :active, 2)

      assert active.source_revision == 3
      assert {:ok, cleared} = messaging.clear_thread_continuity(records.thread.id, 3)
      assert cleared.source_revision == 4
      assert cleared.continuity_ref.request_id == nil
      assert cleared.continuity_ref.turn_id == nil
      assert cleared.continuity_ref.snapshot_id == nil

      assert {:error, {:continuity_cleared, "integration_cleared"}} =
               messaging.resolve_thread_continuity(records.thread.id, scope)

      assert {:error, :continuity_terminal} =
               messaging.set_thread_continuity_status(records.thread.id, :active, 4)

      replacement =
        attrs
        |> put_in([:continuity_ref, :session_id], "session-after-clear")
        |> Map.put(:transition_ref, "jidoka-replacement-after-clear")
        |> Map.put(:source_revision, 5)
        |> Map.put(:source_updated_at, DateTime.add(attrs.source_updated_at, 5, :second))

      assert {:ok, %{status: :active}} = messaging.put_thread_continuity(replacement)
    end
  end

  test "expired and deleted Jidoka references have explicit outcomes" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "lifecycle")

      expired_attrs =
        records
        |> continuity_attrs("session-expired")
        |> put_in([:continuity_ref, :expires_at], DateTime.add(DateTime.utc_now(), -1, :second))

      assert {:ok, _link} = messaging.put_thread_continuity(expired_attrs)
      assert {:ok, scope} = messaging.history_scope([records.room.id])

      assert {:error, {:continuity_expired, "reference_expired"}} =
               messaging.resolve_thread_continuity(records.thread.id, scope)

      deleted_thread = create_thread!(messaging, records.other_room.id, "deleted")

      deleted_attrs =
        continuity_attrs(
          %{records | room: records.other_room, thread: deleted_thread},
          "session-deleted"
        )

      assert {:ok, _link} = messaging.put_thread_continuity(deleted_attrs)

      assert {:ok, _deleted} =
               messaging.set_thread_continuity_status(
                 deleted_thread.id,
                 :deleted,
                 1,
                 reason_code: "jidoka_session_deleted"
               )

      assert {:ok, deleted_scope} = messaging.history_scope([records.other_room.id])

      assert {:error, {:continuity_deleted, "jidoka_session_deleted"}} =
               messaging.resolve_thread_continuity(deleted_thread.id, deleted_scope)
    end
  end

  test "SQLite restores only the reference after a messaging restart" do
    path = sqlite_path("continuity-restart")
    cleanup_sqlite(path)
    on_exit(fn -> cleanup_sqlite(path) end)

    start_supervised!({RestartMessaging, persistence_opts: [path: path]})
    records = seed(RestartMessaging, "restart")
    attrs = continuity_attrs(records, "session-restart")

    assert {:ok, saved} = RestartMessaging.put_thread_continuity(attrs)
    assert {:ok, scope} = RestartMessaging.history_scope([records.room.id])
    :ok = stop_supervised(RestartMessaging)

    start_supervised!({RestartMessaging, persistence_opts: [path: path]})
    assert {:ok, restored} = RestartMessaging.get_thread_continuity(records.thread.id, scope)
    assert restored == saved

    assert Map.keys(Map.from_struct(restored.continuity_ref)) |> Enum.sort() ==
             [:expires_at, :integration_id, :jidoka_agent_ref, :request_id, :session_id, :snapshot_id, :turn_id]

    assert :ok = RestartMessaging.delete_room(records.room.id)
    assert {:error, :not_found} = RestartMessaging.get_thread_continuity(records.thread.id, scope)
  end

  test "principal deletion removes orphaned continuity links" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "principal-delete")
      assert {:ok, _link} = messaging.put_thread_continuity(continuity_attrs(records, "session-delete"))
      assert {:ok, scope} = messaging.history_scope([records.room.id])

      runtime = messaging.__jido_messaging__(:runtime)
      {persistence, state} = Jido.Messaging.Runtime.get_persistence(runtime)
      assert :ok = persistence.delete_participant(state, records.agent.id)
      assert {:error, :not_found} = messaging.get_thread_continuity(records.thread.id, scope)
    end
  end

  test "concurrent claims produce one live session owner" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "concurrent")
      second_thread = create_thread!(messaging, records.other_room.id, "concurrent-second")

      first_attrs = continuity_attrs(records, "session-concurrent")

      second_attrs =
        continuity_attrs(
          %{records | room: records.other_room, thread: second_thread},
          "session-concurrent"
        )

      results =
        [first_attrs, second_attrs]
        |> Task.async_stream(&messaging.put_thread_continuity/1,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %ThreadContinuityLink{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:continuity_session_scope_conflict, _}}, &1)) == 1
    end
  end

  defp messaging_modules, do: [ETSMessaging, SQLiteMessaging]

  defp seed(messaging, suffix) do
    prefix = messaging |> Module.split() |> List.last() |> String.downcase()
    base = "#{prefix}-#{suffix}"

    {:ok, room} = messaging.create_room(%{id: "#{base}-room", type: :group})
    {:ok, other_room} = messaging.create_room(%{id: "#{base}-other-room", type: :group})

    {:ok, agent} =
      messaging.create_participant(%{
        id: "#{base}-agent",
        type: :agent,
        identity: %{name: "Jidoka Support Agent"}
      })

    {:ok, human} =
      messaging.create_participant(%{
        id: "#{base}-human",
        type: :human,
        identity: %{name: "Customer"}
      })

    thread = create_thread!(messaging, room.id, "#{base}-thread")

    {:ok, first_message} =
      messaging.save_message(%{
        id: "#{base}-message-1",
        room_id: room.id,
        thread_id: thread.id,
        sender_id: human.id,
        role: :user,
        content: [%Text{text: "Can you continue?"}],
        status: :sent,
        inserted_at: DateTime.from_unix!(1_700_000_000)
      })

    {:ok, second_message} =
      messaging.save_message(%{
        id: "#{base}-message-2",
        room_id: room.id,
        thread_id: thread.id,
        sender_id: agent.id,
        role: :assistant,
        content: [%Text{text: "Yes."}],
        status: :sent,
        inserted_at: DateTime.from_unix!(1_700_000_001)
      })

    {:ok, room_message} =
      messaging.save_message(%{
        id: "#{base}-room-message",
        room_id: room.id,
        sender_id: human.id,
        role: :user,
        content: [%Text{text: "Not part of the thread"}],
        status: :sent,
        inserted_at: DateTime.from_unix!(1_700_000_002)
      })

    {:ok, cross_room_message} =
      messaging.save_message(%{
        id: "#{base}-cross-room-message",
        room_id: other_room.id,
        thread_id: thread.id,
        sender_id: human.id,
        role: :user,
        content: [%Text{text: "Wrong room for this thread"}],
        status: :sent,
        inserted_at: DateTime.from_unix!(1_700_000_003)
      })

    %{
      room: room,
      other_room: other_room,
      agent: agent,
      human: human,
      thread: thread,
      thread_messages: [first_message, second_message],
      room_message: room_message,
      cross_room_message: cross_room_message
    }
  end

  defp create_thread!(messaging, room_id, suffix) do
    {:ok, thread} =
      messaging.save_thread(%{
        id: "thread-#{suffix}",
        room_id: room_id,
        status: :active
      })

    thread
  end

  defp continuity_attrs(records, session_id) do
    %{
      room_id: records.room.id,
      thread_id: records.thread.id,
      principal_id: records.agent.id,
      continuity_ref: %{
        integration_id: "jidoka-primary",
        jidoka_agent_ref: %{system: :jidoka, id: "support-agent"},
        session_id: session_id,
        request_id: "request-1",
        turn_id: "turn-1",
        snapshot_id: "snapshot-1"
      },
      source_revision: 1,
      source_updated_at: DateTime.utc_now()
    }
  end

  defp sqlite_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "jido-messaging-#{suffix}-#{System.unique_integer([:positive])}.sqlite3"
    )
  end

  defp cleanup_sqlite(path) do
    Enum.each([path, path <> "-shm", path <> "-wal"], &File.rm/1)
  end
end
