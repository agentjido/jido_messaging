defmodule Jido.Messaging.JidokaRecordInputBoundaryTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    @saves [:save_thread_continuity_link, :save_jidoka_delegation_event, :save_trust_evidence]
    for {name, arity} <- ETS.__info__(:functions), name not in @saves do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    for name <- @saves do
      def unquote(name)(state, record) do
        Agent.update(__MODULE__.Control, &(&1 + 1))
        ETS.unquote(name)(state, record)
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{id: Store.Control, start: {Agent, :start_link, [fn -> 0 end, [name: Store.Control]]}})
    start_supervised!(Instance)
    contexts = Enum.map(["owned", "foreign"], &seed/1)

    records =
      for context <- contexts, kind <- [:continuity, :delegation, :evidence] do
        assert {:ok, record} = create(kind, attrs(kind, context), context)
        {kind, record}
      end

    Agent.update(Store.Control, fn _ -> 0 end)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)
    {:ok, contexts: contexts, owned: hd(contexts), records: records, runtime: runtime, state: state}
  end

  for kind <- [:continuity, :delegation, :evidence] do
    test "#{kind} invalid canonical references retain every owned and foreign record", context do
      fields =
        case unquote(kind) do
          :continuity -> [:room_id, :thread_id, :principal_id]
          :delegation -> [:room_id, :thread_id, :source_principal_id, :target_principal_id, :transport_id]
          :evidence -> [:room_id, :subject_principal_id, :issuer_principal_id]
        end

      for field <- fields, value <- [nil, 1, " ", String.duplicate("x", 513), <<255>>, "bad\0id"] do
        reject(unquote(kind), Map.put(attrs(unquote(kind), context.owned), field, value), context)
      end
    end

    test "#{kind} unsafe or duplicate fields cause no save callback", context do
      input = attrs(unquote(kind), context.owned)

      for field <- [:token, :context, :memory, :output],
          do: reject(unquote(kind), Map.put(input, field, %{private: self()}), context)

      reject(unquote(kind), Map.put(input, "room_id", input.room_id), context)
    end

    test "#{kind} malformed nested Jidoka references cannot change identity", context do
      path =
        case unquote(kind) do
          :continuity -> [:continuity_ref, :jidoka_agent_ref]
          :delegation -> [:delegation_ref, :source_agent_ref]
          :evidence -> [:subject_jidoka_agent_ref]
        end

      for reference <- [
            nil,
            self(),
            %{},
            %{system: :foreign, id: "agent"},
            %{system: :jidoka, id: <<255>>},
            %{:system => :jidoka, :id => "agent", "id" => "other"}
          ] do
        reject(unquote(kind), put_in(attrs(unquote(kind), context.owned), path, reference), context)
      end
    end

    test "#{kind} string-key input reuses the complete canonical record", context do
      input = attrs(unquote(kind), context.owned) |> string_keys()

      original =
        Enum.find_value(context.records, fn {type, record} ->
          if type == unquote(kind) and record.room_id == context.owned.room.id, do: record
        end)

      assert {:ok, ^original} = create(unquote(kind), input, context.owned)
      assert Agent.get(Store.Control, & &1) == 1
      assert_records(context)
      assert_no_authority(context)
    end
  end

  test "continuity status, revision and source time failures cannot change a live link", context do
    input = attrs(:continuity, context.owned)

    for {field, values} <- [
          status: [:invalid, "invalid", 1],
          source_revision: [nil, 0, -1, "1"],
          source_updated_at: [nil, 1, "now", DateTime.add(DateTime.utc_now(), 600, :second)],
          reason_code: [1, "bad code", String.duplicate("x", 129)]
        ] do
      for value <- values, do: reject(:continuity, Map.put(input, field, value), context)
    end

    for value <- [1, "not-a-date"],
        do: reject(:continuity, put_in(input, [:continuity_ref, :expires_at], value), context)
  end

  test "delegation codes, enum values, sequences and bounded lists reject without truncation", context do
    input = attrs(:delegation, context.owned)
    for action <- [:invalid, "invalid", 1], do: reject(:delegation, Map.put(input, :action, action), context)

    for value <- [nil, " ", 1, "bad code", String.duplicate("x", 129)],
        do: reject(:delegation, put_in(input, [:emission_ref, :event], value), context)

    for value <- [-1, "1", :invalid],
        do: reject(:delegation, put_in(input, [:emission_ref, :loop_index], value), context)

    for {field, values} <- [
          related_message_ids: [nil, :invalid, [1], ["same", "same"], Enum.map(1..51, &"message-#{&1}")],
          visited_nodes: [nil, :invalid, [1], ["same", "same"], Enum.map(1..17, &"node-#{&1}")]
        ] do
      for value <- values, do: reject(:delegation, Map.put(input, field, value), context)
    end
  end

  test "evidence code, revision, enum and validity failures cannot become a claim", context do
    input = attrs(:evidence, context.owned)

    for {field, values} <- [
          outcome: [:invalid, "invalid", 1],
          verification_state: [:invalid, "invalid", 1],
          capability_scope: [
            nil,
            [],
            :invalid,
            [1],
            [" "],
            ["bad code"],
            [String.duplicate("x", 129)],
            Enum.map(1..33, &"capability-#{&1}")
          ],
          observed_at: [nil, "now", 1, DateTime.add(DateTime.utc_now(), 600, :second)],
          expires_at: [nil, "now", input.observed_at, DateTime.add(input.observed_at, 367, :day)]
        ] do
      for value <- values, do: reject(:evidence, Map.put(input, field, value), context)
    end

    for value <- [nil, 0, -1, "1", 9_223_372_036_854_775_808],
        do: reject(:evidence, put_in(input, [:source, :revision], value), context)

    for value <- [nil, 1, " ", "bad code", String.duplicate("x", 129)],
        do: reject(:evidence, put_in(input, [:source, :provider_id], value), context)
  end

  test "invalid attestation lists cannot create delegation or evidence scopes", context do
    for refs <- [nil, [], :invalid, [1], ["same", "same"], Enum.map(1..33, &"ref-#{&1}")] do
      attrs =
        context.owned.delegation_scope
        |> Map.from_struct()
        |> Map.delete(:instance_module)
        |> Map.put(:source_authorization_refs, refs)

      assert {:error, :invalid_jidoka_delegation_scope} = Instance.jidoka_delegation_scope(attrs)

      attrs =
        context.owned.evidence_scope
        |> Map.from_struct()
        |> Map.delete(:instance_module)
        |> Map.put(:subject_membership_refs, refs)

      assert {:error, :invalid_trust_evidence_scope} = Instance.trust_evidence_scope(attrs)
      assert_unchanged(context)
    end
  end

  defp seed(prefix) do
    {:ok, room} = Instance.create_room(%{id: prefix <> "-room", type: :group, metadata: %{complete: prefix}})
    {:ok, thread} = Instance.save_thread(%{id: prefix <> "-thread", room_id: room.id, status: :active})
    {:ok, source} = Instance.create_participant(%{id: prefix <> "-source", type: :agent})
    {:ok, target} = Instance.create_participant(%{id: prefix <> "-target", type: :agent})
    {:ok, human} = Instance.create_participant(%{id: prefix <> "-reviewer", type: :human})

    {:ok, message} =
      Instance.save_message(%{
        id: prefix <> "-message",
        room_id: room.id,
        thread_id: thread.id,
        sender_id: human.id,
        role: :user,
        content: [%{type: :text, text: "Complete " <> prefix}],
        metadata: %{complete: prefix}
      })

    {:ok, delegation_scope} =
      Instance.jidoka_delegation_scope(%{
        room_id: room.id,
        thread_id: thread.id,
        source_principal_id: source.id,
        target_principal_id: target.id,
        source_authorization_refs: ["grant:source"],
        target_authorization_refs: ["grant:target"]
      })

    {:ok, evidence_scope} =
      Instance.trust_evidence_scope(%{
        room_id: room.id,
        requester_principal_id: human.id,
        subject_principal_id: target.id,
        subject_jidoka_agent_ref: %{system: :jidoka, id: prefix <> "-target-agent"},
        requester_authorization_refs: ["grant:reviewer"],
        subject_membership_refs: ["membership:target"]
      })

    %{
      prefix: prefix,
      room: room,
      thread: thread,
      source: source,
      target: target,
      human: human,
      message: message,
      delegation_scope: delegation_scope,
      evidence_scope: evidence_scope,
      time: DateTime.utc_now()
    }
  end

  defp attrs(:continuity, c) do
    %{
      room_id: c.room.id,
      thread_id: c.thread.id,
      principal_id: c.target.id,
      continuity_ref: %{
        integration_id: "fixture",
        jidoka_agent_ref: %{system: :jidoka, id: c.prefix <> "-target-agent"},
        session_id: c.prefix <> "-session",
        request_id: "request",
        turn_id: "turn",
        snapshot_id: "snapshot"
      },
      source_revision: 1,
      source_updated_at: c.time
    }
  end

  defp attrs(:delegation, c) do
    effect = c.prefix <> "-effect"

    %{
      action: :result,
      room_id: c.room.id,
      thread_id: c.thread.id,
      source_principal_id: c.source.id,
      target_principal_id: c.target.id,
      delegation_ref: %{
        kind: :subagent,
        id: effect,
        effect_id: effect,
        request_id: c.prefix <> "-request",
        source_agent_ref: %{system: :jidoka, id: c.prefix <> "-source-agent"},
        target_agent_ref: %{system: :jidoka, id: c.prefix <> "-target-agent"}
      },
      emission_ref: %{
        source: :operation_result,
        event: :operation_result,
        request_id: c.prefix <> "-request",
        effect_id: effect,
        loop_index: 0
      },
      related_message_ids: [c.message.id],
      transport_id: c.prefix <> "-transport",
      visited_nodes: []
    }
  end

  defp attrs(:evidence, c) do
    %{
      room_id: c.room.id,
      subject_principal_id: c.target.id,
      subject_jidoka_agent_ref: %{system: :jidoka, id: c.prefix <> "-target-agent"},
      issuer_principal_id: c.human.id,
      capability_scope: ["text"],
      outcome: :succeeded,
      source: %{kind: :provider_record, provider_id: "fixture", id: c.prefix <> "-review", revision: 1},
      verification_state: :verified,
      verification_ref: "review:complete",
      observed_at: c.time,
      expires_at: DateTime.add(c.time, 3_600, :second)
    }
  end

  defp create(:continuity, attrs, _c), do: Instance.put_thread_continuity(attrs)
  defp create(:delegation, attrs, c), do: Instance.record_jidoka_delegation_event(attrs, c.delegation_scope)
  defp create(:evidence, attrs, c), do: Instance.record_trust_evidence(attrs, c.evidence_scope)

  defp reject(kind, attrs, context) do
    code =
      %{
        continuity: :invalid_thread_continuity_link,
        delegation: :invalid_jidoka_delegation_event,
        evidence: :invalid_trust_evidence
      }[kind]

    assert {:error, ^code} = create(kind, attrs, context.owned)
    assert_unchanged(context)
  end

  defp assert_unchanged(context) do
    assert Agent.get(Store.Control, & &1) == 0
    assert_records(context)
    assert_no_authority(context)
  end

  defp assert_records(context) do
    for {kind, record} <- context.records do
      case kind do
        :continuity ->
          assert({:ok, record} == ETS.get_thread_continuity_link(context.state, record.thread_id))

        :delegation ->
          assert({:ok, record} == ETS.get_jidoka_delegation_event(context.state, record.id))

        :evidence ->
          assert({:ok, [record]} == ETS.list_trust_evidence(context.state, record.subject_principal_id, record.room_id))
      end
    end

    for c <- context.contexts do
      assert {:ok, room} = ETS.get_room(context.state, c.room.id)
      assert room == c.room
      assert {:ok, thread} = ETS.get_thread(context.state, c.thread.id)
      assert thread == c.thread
      assert {:ok, message} = ETS.get_message(context.state, c.message.id)
      assert message == c.message
    end
  end

  defp assert_no_authority(context) do
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert Instance.count_agents() == 0
  end

  defp string_keys(value) when is_map(value) and not is_struct(value),
    do:
      Map.new(value, fn {key, nested} -> {if(is_atom(key), do: Atom.to_string(key), else: key), string_keys(nested)} end)

  defp string_keys(value) when is_list(value), do: Enum.map(value, &string_keys/1)
  defp string_keys(value), do: value
end
