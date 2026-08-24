defmodule Jido.Messaging.MessagingActivityProjectionTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3

  alias Jido.Messaging.{
    JidokaExecutionRef,
    MessagingActivityEntry,
    MessagingActivitySummary,
    Persistence
  }

  defmodule ActivityMessaging do
    use Jido.Messaging
  end

  for adapter <- [Persistence.ETS, Persistence.SQLite] do
    test "#{inspect(adapter)} projects complete messaging correlation without changing authorship" do
      with_runtime(unquote(adapter), fn messaging ->
        records = create_records(messaging)

        assert {:ok, request_entry} =
                 messaging.project_messaging_activity(activity_attrs(records, "event:request", :request, :running, 1))

        assert {:ok, approval_entry} =
                 messaging.project_messaging_activity(
                   activity_attrs(records, "event:approval", :approval, :approved, 1,
                     summary: %{outcome: :none, code: "approval.granted", label: "Approved by operator"}
                   )
                 )

        assert {:ok, outcome_entry} =
                 messaging.project_messaging_activity(
                   activity_attrs(records, "event:outcome", :outcome, :completed, 1,
                     message_id: records.agent_message.id,
                     summary: %{outcome: :succeeded, code: "turn.complete", label: "Reply sent"}
                   )
                 )

        assert request_entry.principal_id == records.agent.id
        assert request_entry.room_id == records.room.id
        assert request_entry.thread_id == records.thread.id
        assert request_entry.message_id == records.inbound_message.id
        assert request_entry.execution_ref.session_id == "jidoka-session:one"
        assert request_entry.execution_ref.request_id == "jidoka-request:one"
        assert request_entry.execution_ref.turn_id == "jidoka-turn:one"
        assert request_entry.execution_ref.handoff_id == "jidoka-handoff:one"
        assert request_entry.execution_ref.approval_id == "jidoka-approval:one"

        assert {:ok, scope} = messaging.history_scope([records.room.id])
        assert {:ok, entries} = messaging.principal_activity(records.agent.id, scope, limit: 10)

        assert Enum.map(entries, & &1.id) ==
                 Enum.map([request_entry, approval_entry, outcome_entry], & &1.id)

        assert Enum.all?(entries, &match?(%MessagingActivityEntry{}, &1))
        assert outcome_entry.summary.outcome == :succeeded
        assert outcome_entry.execution_ref.detail_availability == :available

        assert {:ok, inbound} = messaging.get_message(records.inbound_message.id)
        assert {:ok, outbound} = messaging.get_message(records.agent_message.id)
        assert inbound.sender_id == records.human.id
        assert outbound.sender_id == records.agent.id
      end)
    end

    test "#{inspect(adapter)} enforces source revisions and immutable correlation" do
      with_runtime(unquote(adapter), fn messaging ->
        records = create_records(messaging)
        attrs = activity_attrs(records, "event:revision", :turn, :running, 4)

        assert {:ok, first} = messaging.project_messaging_activity(attrs)
        assert {:ok, idempotent} = messaging.project_messaging_activity(attrs)
        assert idempotent == first

        assert {:error, :activity_projection_conflict} =
                 messaging.project_messaging_activity(%{
                   attrs
                   | status: :failed,
                     summary: %{outcome: :failed, code: "turn.failed"}
                 })

        revised_attrs = %{
          attrs
          | source_revision: 6,
            status: :completed,
            summary: %{outcome: :succeeded, code: "turn.complete"},
            execution_ref: %{
              attrs.execution_ref
              | detail_availability: :expired,
                detail_ref: nil,
                detail_expires_at: DateTime.utc_now()
            }
        }

        assert {:ok, revised} = messaging.project_messaging_activity(revised_attrs)
        assert revised.id == first.id
        assert revised.inserted_at == first.inserted_at
        assert revised.source_revision == 6
        assert revised.status == :completed
        assert revised.execution_ref.detail_availability == :expired

        assert {:error, {:stale_activity_revision, 6}} =
                 messaging.project_messaging_activity(%{attrs | source_revision: 5})

        changed_request =
          revised_attrs
          |> put_in([:execution_ref, :request_id], "jidoka-request:different")
          |> Map.put(:source_revision, 7)

        assert {:error, :activity_correlation_immutable} =
                 messaging.project_messaging_activity(changed_request)
      end)
    end
  end

  test "principal activity cannot cross room or messaging instance scope" do
    with_runtime(Persistence.ETS, fn messaging ->
      records = create_records(messaging)
      {:ok, denied_room} = messaging.create_room(%{id: "room:denied", type: :group})

      {:ok, allowed} =
        messaging.project_messaging_activity(activity_attrs(records, "event:allowed", :request, :running, 1))

      denied_attrs =
        records
        |> activity_attrs("event:denied", :request, :running, 1,
          room_id: denied_room.id,
          thread_id: nil,
          message_id: nil
        )

      assert {:ok, denied} = messaging.project_messaging_activity(denied_attrs)
      assert {:ok, allowed_scope} = messaging.history_scope([records.room.id])

      assert {:ok, [^allowed]} = messaging.principal_activity(records.agent.id, allowed_scope)

      assert {:error, :cursor_not_found} =
               messaging.principal_activity(records.agent.id, allowed_scope, before: denied.id)

      assert {:error, :history_scope_required} =
               messaging.principal_activity(records.agent.id, %{room_ids: [records.room.id]})

      foreign_scope = %{allowed_scope | instance_module: ForeignMessaging}

      assert {:error, :history_scope_instance_mismatch} =
               messaging.principal_activity(records.agent.id, foreign_scope)
    end)
  end

  test "projection input rejects runtime journals and unsafe summary fields" do
    with_runtime(Persistence.ETS, fn messaging ->
      records = create_records(messaging)
      attrs = activity_attrs(records, "event:unsafe", :turn, :running, 1)

      assert {:error, :invalid_messaging_activity_projection} =
               messaging.project_messaging_activity(Map.put(attrs, :raw_event, %{prompt: "secret"}))

      assert {:error, :invalid_messaging_activity_projection} =
               messaging.project_messaging_activity(%{
                 attrs
                 | summary: %{outcome: :none, prompt: "do not persist"}
               })

      assert {:error, :invalid_messaging_activity_projection} =
               messaging.project_messaging_activity(%{
                 attrs
                 | execution_ref: Map.put(attrs.execution_ref, :tool_arguments, %{token: "secret"})
               })

      assert {:error, :invalid_messaging_activity_projection} =
               messaging.project_messaging_activity(%{
                 attrs
                 | summary: %{outcome: :failed, code: "contains spaces"}
               })

      assert {:error, :invalid_messaging_activity_projection} =
               messaging.project_messaging_activity(%{
                 attrs
                 | status: :completed,
                   summary: %{outcome: :failed, code: "turn.failed"}
               })

      assert {:error, :invalid_messaging_activity_projection} =
               messaging.project_messaging_activity(%{
                 attrs
                 | execution_ref: %{
                     attrs.execution_ref
                     | detail_availability: :available,
                       detail_ref: nil
                   }
               })
    end)
  end

  test "projection validates canonical room, thread, and message correlation" do
    with_runtime(Persistence.ETS, fn messaging ->
      records = create_records(messaging)
      {:ok, other_room} = messaging.create_room(%{id: "room:other", type: :group})

      assert {:error, :activity_thread_room_mismatch} =
               messaging.project_messaging_activity(
                 activity_attrs(records, "event:thread-mismatch", :turn, :running, 1,
                   room_id: other_room.id,
                   message_id: nil
                 )
               )

      assert {:error, :activity_message_scope_mismatch} =
               messaging.project_messaging_activity(
                 activity_attrs(records, "event:message-mismatch", :turn, :running, 1,
                   room_id: other_room.id,
                   thread_id: nil
                 )
               )

      assert {:error, :activity_principal_must_be_agent} =
               messaging.project_messaging_activity(
                 activity_attrs(records, "event:human-principal", :turn, :running, 1, principal_id: records.human.id)
               )
    end)
  end

  test "activity pagination has stable before and after cursors" do
    with_runtime(Persistence.SQLite, fn messaging ->
      records = create_records(messaging)
      base_time = DateTime.from_unix!(1_700_000_000)

      entries =
        for index <- 1..4 do
          {:ok, entry} =
            messaging.project_messaging_activity(
              activity_attrs(records, "event:page:#{index}", :turn, :running, 1,
                source_recorded_at: DateTime.add(base_time, index, :second)
              )
            )

          entry
        end

      assert {:ok, scope} = messaging.history_scope([records.room.id])
      assert {:ok, latest} = messaging.principal_activity(records.agent.id, scope, limit: 2)
      assert Enum.map(latest, & &1.id) == entries |> Enum.take(-2) |> Enum.map(& &1.id)

      assert {:ok, before} =
               messaging.principal_activity(records.agent.id, scope,
                 before: List.last(entries).id,
                 limit: 10
               )

      assert Enum.map(before, & &1.id) == entries |> Enum.drop(-1) |> Enum.map(& &1.id)

      assert {:ok, after_entries} =
               messaging.principal_activity(records.agent.id, scope,
                 after: List.first(entries).id,
                 limit: 10
               )

      assert Enum.map(after_entries, & &1.id) == entries |> Enum.drop(1) |> Enum.map(& &1.id)
    end)
  end

  test "an elapsed Jidoka detail deadline hides the navigation reference" do
    with_runtime(Persistence.ETS, fn messaging ->
      records = create_records(messaging)

      attrs =
        activity_attrs(records, "event:expired-detail", :turn, :completed, 1,
          summary: %{outcome: :succeeded, code: "turn.complete"},
          execution_ref: %{
            integration_id: "jidoka:primary",
            session_id: "jidoka-session:one",
            request_id: "jidoka-request:one",
            turn_id: "jidoka-turn:one",
            detail_ref: "jidoka://trace/expired-turn",
            detail_availability: :available,
            detail_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
          }
        )

      assert {:ok, stored} = messaging.project_messaging_activity(attrs)
      assert stored.execution_ref.detail_availability == :available

      assert {:ok, scope} = messaging.history_scope([records.room.id])
      assert {:ok, [effective]} = messaging.principal_activity(records.agent.id, scope)
      assert effective.execution_ref.detail_availability == :expired
      assert effective.execution_ref.detail_ref == nil
    end)
  end

  test "deleting a room removes its safe activity projection" do
    for adapter <- [Persistence.ETS, Persistence.SQLite] do
      with_runtime(adapter, fn messaging ->
        records = create_records(messaging)

        assert {:ok, _entry} =
                 messaging.project_messaging_activity(
                   activity_attrs(records, "event:room-delete", :request, :running, 1)
                 )

        assert {:ok, scope} = messaging.history_scope([records.room.id])
        assert {:ok, [_entry]} = messaging.principal_activity(records.agent.id, scope)
        assert :ok = messaging.delete_room(records.room.id)
        assert {:ok, []} = messaging.principal_activity(records.agent.id, scope)
      end)
    end
  end

  test "SQLite keeps activity projections and unavailable detail across restarts" do
    path = tmp_path("activity-restart")
    {:ok, state} = Persistence.SQLite.init(path: path)

    entry =
      MessagingActivityEntry.new(%{
        principal_id: "principal:agent",
        room_id: "room:one",
        kind: :outcome,
        status: :unavailable,
        summary: %{outcome: :unknown, code: "detail.unavailable"},
        execution_ref: %{
          integration_id: "jidoka:primary",
          session_id: "session:one",
          request_id: "request:one",
          detail_availability: :unavailable
        },
        source_event_id: "event:one",
        source_event_type: "jidoka.turn.unavailable",
        source_revision: 1,
        source_recorded_at: DateTime.from_unix!(1_700_000_000)
      })

    assert {:ok, ^entry} = Persistence.SQLite.save_messaging_activity(state, entry)
    :ok = Sqlite3.close(state.db)
    {:ok, restarted} = Persistence.SQLite.init(path: path)

    assert {:ok, ^entry} = Persistence.SQLite.get_messaging_activity(restarted, entry.id)

    assert {:ok, [^entry]} =
             Persistence.SQLite.get_principal_activity(
               restarted,
               entry.principal_id,
               [entry.room_id]
             )

    :ok = Sqlite3.close(restarted.db)
  end

  test "execution and summary structs contain only bounded navigation data" do
    reference =
      JidokaExecutionRef.new(%{
        integration_id: "jidoka:primary",
        session_id: "session:one",
        request_id: "request:one",
        detail_availability: :restricted
      })

    summary = MessagingActivitySummary.new(%{outcome: :denied, code: "approval.denied"})

    assert reference.detail_ref == nil
    assert reference.detail_availability == :restricted
    assert summary.outcome == :denied
    assert summary.label == nil
    refute Map.has_key?(Map.from_struct(reference), :event)
    refute Map.has_key?(Map.from_struct(summary), :result)
  end

  defp with_runtime(adapter, fun) do
    path = tmp_path("activity-runtime")

    opts =
      if adapter == Persistence.SQLite,
        do: [persistence: adapter, persistence_opts: [path: path]],
        else: [persistence: adapter]

    start_supervised!({ActivityMessaging, opts})

    try do
      fun.(ActivityMessaging)
    after
      stop_supervised(ActivityMessaging)
      File.rm(path)
    end
  end

  defp create_records(messaging) do
    {:ok, room} = messaging.create_room(%{id: "room:activity", type: :group})

    {:ok, human} =
      messaging.create_participant(%{
        id: "principal:human",
        type: :human,
        identity: %{name: "Operator"}
      })

    {:ok, agent} =
      messaging.create_participant(%{
        id: "principal:agent",
        type: :agent,
        identity: %{name: "Jidoka Agent"}
      })

    {:ok, thread} =
      messaging.save_thread(%{
        id: "thread:activity",
        room_id: room.id,
        root_message_id: "message:inbound"
      })

    {:ok, inbound_message} =
      messaging.save_message(%{
        id: "message:inbound",
        room_id: room.id,
        thread_id: thread.id,
        sender_id: human.id,
        role: :user,
        content: [%{type: :text, text: "Please run the task"}]
      })

    {:ok, agent_message} =
      messaging.save_message(%{
        id: "message:agent",
        room_id: room.id,
        thread_id: thread.id,
        sender_id: agent.id,
        role: :assistant,
        content: [%{type: :text, text: "Task complete"}]
      })

    %{
      room: room,
      human: human,
      agent: agent,
      thread: thread,
      inbound_message: inbound_message,
      agent_message: agent_message
    }
  end

  defp activity_attrs(records, event_id, kind, status, revision, overrides \\ []) do
    base = %{
      principal_id: records.agent.id,
      room_id: records.room.id,
      thread_id: records.thread.id,
      message_id: records.inbound_message.id,
      kind: kind,
      status: status,
      summary: %{outcome: :none, code: "activity.projected"},
      execution_ref: %{
        integration_id: "jidoka:primary",
        session_id: "jidoka-session:one",
        request_id: "jidoka-request:one",
        turn_id: "jidoka-turn:one",
        handoff_id: "jidoka-handoff:one",
        approval_id: "jidoka-approval:one",
        detail_ref: "jidoka://trace/turn-one",
        detail_availability: :available,
        detail_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      },
      source_event_id: event_id,
      source_event_type: "jidoka.#{kind}.#{status}",
      source_revision: revision,
      source_recorded_at: DateTime.add(DateTime.from_unix!(1_700_000_000), event_sequence(event_id), :second)
    }

    Enum.reduce(overrides, base, fn {key, value}, attrs -> Map.put(attrs, key, value) end)
  end

  defp event_sequence("event:request"), do: 1
  defp event_sequence("event:approval"), do: 2
  defp event_sequence("event:outcome"), do: 3
  defp event_sequence(event_id), do: :erlang.phash2(event_id, 10_000)

  defp tmp_path(prefix) do
    Path.join(System.tmp_dir!(), "jido-messaging-#{prefix}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
