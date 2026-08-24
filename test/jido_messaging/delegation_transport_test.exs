defmodule Jido.Messaging.DelegationTransportTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Content.Text

  alias Jido.Messaging.{
    JidokaDelegationContext,
    JidokaDelegationEvent,
    JidokaDelegationScope,
    JidokaEmissionRef
  }

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
    path = sqlite_path("delegation")
    cleanup_sqlite(path)

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    on_exit(fn -> cleanup_sqlite(path) end)
    :ok
  end

  test "ETS and SQLite transport a scoped subagent result without its output or context" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "subagent-result")
      scope = scope!(messaging, records)
      attrs = subagent_result_attrs(records, "result", [records.thread_message.id])

      assert {:ok, %JidokaDelegationEvent{} = event} =
               messaging.record_jidoka_delegation_event(attrs, scope)

      assert event.action == :result
      assert event.delegation_ref.kind == :subagent
      assert event.visited_nodes == ["jido_messaging:#{Atom.to_string(messaging)}"]
      assert {:ok, ^event} = messaging.get_jidoka_delegation_event(event.id, scope)

      assert {:ok, %JidokaDelegationContext{} = context} =
               messaging.jidoka_delegation_context(event.id, scope)

      assert context.event == event
      assert Enum.map(context.messages, & &1.id) == [records.thread_message.id]
      refute Map.has_key?(Map.from_struct(event), :context)
      refute Map.has_key?(Map.from_struct(event), :result)
      refute Map.has_key?(Map.from_struct(event), :output)
      refute Map.has_key?(Map.from_struct(context), :prompt)
    end
  end

  test "handoff route records do not change Jido Messaging agent ownership" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "handoff-route")
      scope = scope!(messaging, records)

      assert {:ok, event} =
               messaging.record_jidoka_delegation_event(
                 handoff_route_attrs(records, "route"),
                 scope
               )

      assert event.action == :route_changed
      assert event.route_ref == "jidoka-owner:conversation-route:target"
      assert event.delegation_ref.handoff_id == "handoff-route"

      assert {:ok, thread} = messaging.get_thread(records.thread.id)
      assert thread.assigned_agent_id == nil
    end
  end

  test "authorization scope is mandatory, instance-bound, and exact before message reads" do
    records = seed(ETSMessaging, "scope")
    attrs = subagent_result_attrs(records, "scope", ["missing-message"])
    valid_scope = scope!(ETSMessaging, records)

    assert {:error, :jidoka_delegation_scope_required} =
             ETSMessaging.record_jidoka_delegation_event(attrs, nil)

    other_instance_scope =
      JidokaDelegationScope.new!(SQLiteMessaging, scope_attrs(records))

    assert {:error, :jidoka_delegation_scope_instance_mismatch} =
             ETSMessaging.record_jidoka_delegation_event(attrs, other_instance_scope)

    wrong_scope =
      records
      |> scope_attrs()
      |> Map.put(:room_id, records.other_room.id)
      |> Map.put(:thread_id, records.other_thread.id)
      |> then(&JidokaDelegationScope.new!(ETSMessaging, &1))

    assert {:error, :jidoka_delegation_scope_violation} =
             ETSMessaging.record_jidoka_delegation_event(attrs, wrong_scope)

    assert {:error, {:jidoka_delegation_message_not_found, "missing-message"}} =
             ETSMessaging.record_jidoka_delegation_event(attrs, valid_scope)

    assert {:error, :invalid_jidoka_delegation_scope} =
             ETSMessaging.jidoka_delegation_scope(Map.put(scope_attrs(records), :target_authorization_refs, []))

    assert {:error, :invalid_jidoka_delegation_scope} =
             ETSMessaging.record_jidoka_delegation_event(
               attrs,
               %{valid_scope | target_authorization_refs: []}
             )
  end

  test "the boundary rejects state payloads, non-Jidoka identities, and human targets" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "strict")
      scope = scope!(messaging, records)
      attrs = subagent_result_attrs(records, "strict", [])

      for unsafe_key <- [:context, :task, :result, :output, :owner, :credentials] do
        assert {:error, :invalid_jidoka_delegation_event} =
                 messaging.record_jidoka_delegation_event(
                   Map.put(attrs, unsafe_key, %{private: true}),
                   scope
                 )
      end

      non_jidoka =
        put_in(
          attrs,
          [:delegation_ref, :target_agent_ref],
          %{system: :jido, id: "target-agent"}
        )

      assert {:error, :invalid_jidoka_delegation_event} =
               messaging.record_jidoka_delegation_event(non_jidoka, scope)

      human_attrs = %{attrs | target_principal_id: records.human.id}

      human_scope =
        records
        |> scope_attrs()
        |> Map.put(:target_principal_id, records.human.id)
        |> then(&JidokaDelegationScope.new!(messaging, &1))

      assert {:error, :jidoka_delegation_principal_not_agent} =
               messaging.record_jidoka_delegation_event(human_attrs, human_scope)
    end
  end

  test "actions must map to the matching Jidoka source contract" do
    records = seed(ETSMessaging, "semantics")
    scope = scope!(ETSMessaging, records)
    subagent = subagent_result_attrs(records, "semantics", [])

    assert {:error, :invalid_jidoka_delegation_event} =
             ETSMessaging.record_jidoka_delegation_event(
               subagent |> Map.put(:action, :route_changed) |> Map.put(:route_ref, "route"),
               scope
             )

    handoff = handoff_route_attrs(records, "semantics")

    assert {:error, :invalid_jidoka_delegation_event} =
             ETSMessaging.record_jidoka_delegation_event(Map.delete(handoff, :route_ref), scope)

    cancelled = cancellation_attrs(records, "semantics")

    assert {:error, :invalid_jidoka_delegation_event} =
             ETSMessaging.record_jidoka_delegation_event(
               Map.delete(cancelled, :reason_code),
               scope
             )

    mismatched_emission =
      put_in(subagent, [:emission_ref, :effect_id], "effect-other")

    assert {:error, :invalid_jidoka_delegation_event} =
             ETSMessaging.record_jidoka_delegation_event(mismatched_emission, scope)

    assert_raise ArgumentError, fn ->
      JidokaEmissionRef.new(%{
        source: :event,
        event: :effect_completed,
        request_id: "request",
        sequence: nil
      })
    end

    planned_ref =
      JidokaEmissionRef.new(%{
        source: :event,
        event: :effect_planned,
        request_id: "request-semantics",
        sequence: 4,
        loop_index: 0,
        effect_id: "effect-semantics"
      })

    failed_ref = JidokaEmissionRef.new(cancelled.emission_ref)
    assert planned_ref.id == failed_ref.id

    requested =
      cancelled
      |> Map.put(:action, :requested)
      |> Map.delete(:reason_code)
      |> Map.put(:transport_id, "transport-requested-semantics")
      |> put_in([:emission_ref, :event], :effect_planned)

    assert {:ok, _event} = ETSMessaging.record_jidoka_delegation_event(requested, scope)

    assert {:error, :jidoka_delegation_emission_conflict} =
             ETSMessaging.record_jidoka_delegation_event(cancelled, scope)
  end

  test "exact retries are idempotent and transport identity cannot be reused" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "dedupe")
      scope = scope!(messaging, records)
      attrs = subagent_result_attrs(records, "dedupe-one", [])

      assert {:ok, first} = messaging.record_jidoka_delegation_event(attrs, scope)
      assert {:ok, ^first} = messaging.record_jidoka_delegation_event(attrs, scope)

      conflict = subagent_result_attrs(records, "dedupe-two", [])
      conflict = %{conflict | transport_id: attrs.transport_id}

      assert {:error, :jidoka_delegation_transport_conflict} =
               messaging.record_jidoka_delegation_event(conflict, scope)

      changed_same_emission = %{attrs | related_message_ids: [records.thread_message.id]}

      assert {:error, :jidoka_delegation_event_conflict} =
               messaging.record_jidoka_delegation_event(changed_same_emission, scope)
    end
  end

  test "transport trace rejects loops, duplicate nodes, and excess hops" do
    records = seed(ETSMessaging, "loop")
    scope = scope!(ETSMessaging, records)
    attrs = subagent_result_attrs(records, "loop", [])
    instance_node = "jido_messaging:#{Atom.to_string(ETSMessaging)}"

    assert {:error, :delegation_transport_loop} =
             ETSMessaging.record_jidoka_delegation_event(
               %{attrs | visited_nodes: ["bridge:slack", instance_node]},
               scope
             )

    max_nodes = Enum.map(1..JidokaDelegationEvent.maximum_hops(), &"bridge:#{&1}")

    assert {:error, :delegation_hop_limit} =
             ETSMessaging.record_jidoka_delegation_event(
               %{attrs | visited_nodes: max_nodes},
               scope
             )

    event = JidokaDelegationEvent.new(attrs)
    assert {:ok, forwarded} = JidokaDelegationEvent.enter(event, "bridge:telegram")

    assert {:error, :delegation_transport_loop} =
             JidokaDelegationEvent.enter(forwarded, "bridge:telegram")

    assert {:error, :invalid_jidoka_delegation_event} =
             ETSMessaging.record_jidoka_delegation_event(
               %{attrs | visited_nodes: ["bridge:one", "bridge:one"]},
               scope
             )
  end

  test "a Jidoka cancellation blocks later delivery records" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "cancel")
      scope = scope!(messaging, records)

      assert {:ok, cancellation} =
               messaging.record_jidoka_delegation_event(
                 cancellation_attrs(records, "cancel"),
                 scope
               )

      assert cancellation.action == :cancelled

      assert {:error, :jidoka_delegation_cancelled} =
               messaging.record_jidoka_delegation_event(
                 subagent_result_attrs(records, "cancel", []),
                 scope
               )

      delivered = subagent_result_attrs(records, "cancel-after-result", [])
      assert {:ok, _result} = messaging.record_jidoka_delegation_event(delivered, scope)

      assert {:ok, _later_cancellation} =
               messaging.record_jidoka_delegation_event(
                 cancellation_attrs(records, "cancel-after-result"),
                 scope
               )

      assert {:error, :jidoka_delegation_cancelled} =
               messaging.record_jidoka_delegation_event(delivered, scope)
    end
  end

  test "related messages cannot cross a sibling thread or another room" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "message-scope")
      scope = scope!(messaging, records)

      for message <- [records.sibling_message, records.other_room_message, records.room_message] do
        attrs = subagent_result_attrs(records, "scope-#{message.id}", [message.id])

        assert {:error, :jidoka_delegation_message_scope_violation} =
                 messaging.record_jidoka_delegation_event(attrs, scope)
      end
    end
  end

  test "closed threads reject delivery but accept Jidoka cancellation" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "closed")
      scope = scope!(messaging, records)
      assert {:ok, _thread} = messaging.save_thread_struct(%{records.thread | status: :closed})

      assert {:error, {:jidoka_delegation_thread_not_active, :closed}} =
               messaging.record_jidoka_delegation_event(
                 subagent_result_attrs(records, "closed", []),
                 scope
               )

      assert {:ok, %{action: :cancelled}} =
               messaging.record_jidoka_delegation_event(
                 cancellation_attrs(records, "closed"),
                 scope
               )
    end
  end

  test "SQLite keeps cancellation protection across a messaging restart" do
    path = sqlite_path("delegation-restart")
    cleanup_sqlite(path)
    on_exit(fn -> cleanup_sqlite(path) end)

    start_supervised!({RestartMessaging, persistence_opts: [path: path]})
    records = seed(RestartMessaging, "restart")
    scope = scope!(RestartMessaging, records)

    assert {:ok, cancellation} =
             RestartMessaging.record_jidoka_delegation_event(
               cancellation_attrs(records, "restart"),
               scope
             )

    :ok = stop_supervised(RestartMessaging)
    start_supervised!({RestartMessaging, persistence_opts: [path: path]})

    assert {:ok, ^cancellation} =
             RestartMessaging.get_jidoka_delegation_event(cancellation.id, scope)

    assert {:error, :jidoka_delegation_cancelled} =
             RestartMessaging.record_jidoka_delegation_event(
               subagent_result_attrs(records, "restart", []),
               scope
             )
  end

  test "concurrent records produce one owner for a transport ID" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "concurrent")
      scope = scope!(messaging, records)
      first = subagent_result_attrs(records, "concurrent-one", [])
      second = subagent_result_attrs(records, "concurrent-two", [])
      second = %{second | transport_id: first.transport_id}

      results =
        [first, second]
        |> Task.async_stream(
          fn attrs -> messaging.record_jidoka_delegation_event(attrs, scope) end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %JidokaDelegationEvent{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :jidoka_delegation_transport_conflict}, &1)) == 1
    end
  end

  test "room deletion removes its delegation transport records" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "delete-room")
      scope = scope!(messaging, records)

      assert {:ok, event} =
               messaging.record_jidoka_delegation_event(
                 subagent_result_attrs(records, "delete-room", []),
                 scope
               )

      assert :ok = messaging.delete_room(records.room.id)
      assert {:error, :not_found} = messaging.get_jidoka_delegation_event(event.id, scope)
    end
  end

  defp messaging_modules, do: [ETSMessaging, SQLiteMessaging]

  defp seed(messaging, suffix) do
    prefix = messaging |> Module.split() |> List.last() |> String.downcase()
    base = "#{prefix}-#{suffix}"

    {:ok, room} = messaging.create_room(%{id: "#{base}-room", type: :group})
    {:ok, other_room} = messaging.create_room(%{id: "#{base}-other-room", type: :group})

    {:ok, source} =
      messaging.create_participant(%{
        id: "#{base}-source",
        type: :agent,
        identity: %{name: "Jidoka Parent"}
      })

    {:ok, target} =
      messaging.create_participant(%{
        id: "#{base}-target",
        type: :agent,
        identity: %{name: "Jidoka Specialist"}
      })

    {:ok, human} =
      messaging.create_participant(%{
        id: "#{base}-human",
        type: :human,
        identity: %{name: "Customer"}
      })

    thread = create_thread!(messaging, room.id, "#{base}-thread")
    other_thread = create_thread!(messaging, other_room.id, "#{base}-other-thread")
    sibling_thread = create_thread!(messaging, room.id, "#{base}-sibling-thread")

    thread_message =
      save_message!(messaging, "#{base}-thread-message", room.id, thread.id, human.id)

    sibling_message =
      save_message!(messaging, "#{base}-sibling-message", room.id, sibling_thread.id, human.id)

    other_room_message =
      save_message!(messaging, "#{base}-other-message", other_room.id, other_thread.id, human.id)

    room_message = save_message!(messaging, "#{base}-room-message", room.id, nil, human.id)

    %{
      room: room,
      other_room: other_room,
      source: source,
      target: target,
      human: human,
      thread: thread,
      other_thread: other_thread,
      sibling_thread: sibling_thread,
      thread_message: thread_message,
      sibling_message: sibling_message,
      other_room_message: other_room_message,
      room_message: room_message
    }
  end

  defp create_thread!(messaging, room_id, id) do
    {:ok, thread} = messaging.save_thread(%{id: id, room_id: room_id, status: :active})
    thread
  end

  defp save_message!(messaging, id, room_id, thread_id, sender_id) do
    {:ok, message} =
      messaging.save_message(%{
        id: id,
        room_id: room_id,
        thread_id: thread_id,
        sender_id: sender_id,
        role: :user,
        content: [%Text{text: "Canonical message"}],
        status: :sent
      })

    message
  end

  defp scope!(messaging, records) do
    {:ok, scope} = messaging.jidoka_delegation_scope(scope_attrs(records))
    scope
  end

  defp scope_attrs(records) do
    %{
      room_id: records.room.id,
      thread_id: records.thread.id,
      source_principal_id: records.source.id,
      target_principal_id: records.target.id,
      source_authorization_refs: ["grant:source:room", "grant:source:thread"],
      target_authorization_refs: ["grant:target:room", "grant:target:thread"]
    }
  end

  defp subagent_result_attrs(records, suffix, message_ids) do
    effect_id = "effect-#{suffix}"
    request_id = "request-#{suffix}"

    %{
      action: :result,
      room_id: records.room.id,
      thread_id: records.thread.id,
      source_principal_id: records.source.id,
      target_principal_id: records.target.id,
      delegation_ref: %{
        kind: :subagent,
        id: effect_id,
        request_id: request_id,
        turn_id: "turn-#{suffix}",
        effect_id: effect_id,
        source_agent_ref: %{system: :jidoka, id: "parent-agent"},
        target_agent_ref: %{system: :jidoka, id: "specialist-agent"}
      },
      emission_ref: %{
        source: :operation_result,
        event: :operation_result,
        request_id: request_id,
        effect_id: effect_id,
        loop_index: 0
      },
      related_message_ids: message_ids,
      transport_id: "transport-#{suffix}",
      visited_nodes: []
    }
  end

  defp handoff_route_attrs(records, suffix) do
    handoff_id = "handoff-#{suffix}"

    %{
      action: :route_changed,
      room_id: records.room.id,
      thread_id: records.thread.id,
      source_principal_id: records.source.id,
      target_principal_id: records.target.id,
      delegation_ref: %{
        kind: :handoff,
        id: handoff_id,
        handoff_id: handoff_id,
        conversation_id: "conversation-#{suffix}",
        request_id: "request-#{suffix}",
        source_agent_ref: %{system: :jidoka, id: "parent-agent"},
        target_agent_ref: %{system: :jidoka, id: "conversation-#{suffix}:specialist"}
      },
      emission_ref: %{
        source: :handoff,
        event: :handoff,
        handoff_id: handoff_id
      },
      related_message_ids: [],
      route_ref: "jidoka-owner:conversation-#{suffix}:target",
      transport_id: "transport-handoff-#{suffix}",
      visited_nodes: []
    }
  end

  defp cancellation_attrs(records, suffix) do
    effect_id = "effect-#{suffix}"
    request_id = "request-#{suffix}"

    %{
      action: :cancelled,
      room_id: records.room.id,
      thread_id: records.thread.id,
      source_principal_id: records.source.id,
      target_principal_id: records.target.id,
      delegation_ref: %{
        kind: :subagent,
        id: effect_id,
        request_id: request_id,
        turn_id: "turn-#{suffix}",
        effect_id: effect_id,
        source_agent_ref: %{system: :jidoka, id: "parent-agent"},
        target_agent_ref: %{system: :jidoka, id: "specialist-agent"}
      },
      emission_ref: %{
        source: :event,
        event: :effect_failed,
        request_id: request_id,
        sequence: 4,
        loop_index: 0,
        effect_id: effect_id
      },
      related_message_ids: [],
      reason_code: "jidoka_cancelled",
      transport_id: "transport-cancelled-#{suffix}",
      visited_nodes: []
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
