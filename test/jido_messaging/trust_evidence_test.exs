defmodule Jido.Messaging.TrustEvidenceTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Content.Text

  alias Jido.Messaging.{
    Runtime,
    TrustEvidence,
    TrustEvidenceResult,
    TrustEvidenceScope
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

  defmodule AvailableProvider do
    @behaviour Jido.Messaging.TrustEvidenceProvider

    @impl true
    def id, do: "review_service"

    @impl true
    def query(_scope, opts), do: {:ok, Keyword.fetch!(opts, :evidence)}
  end

  defmodule UnavailableProvider do
    @behaviour Jido.Messaging.TrustEvidenceProvider

    @impl true
    def id, do: "offline_review_service"

    @impl true
    def query(_scope, _opts), do: {:error, :connection_failed}
  end

  setup do
    path = sqlite_path("trust-evidence")
    cleanup_sqlite(path)

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    on_exit(fn -> cleanup_sqlite(path) end)
    :ok
  end

  test "ETS and SQLite store and query explainable Jidoka trust evidence" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "basic")
      scope = scope!(messaging, records)
      attrs = evidence_attrs(records, "basic")

      assert {:ok, %TrustEvidence{} = evidence} =
               messaging.record_trust_evidence(attrs, scope)

      assert evidence.subject_jidoka_agent_ref == %{
               "system" => "jidoka",
               "id" => "support-agent"
             }

      assert evidence.capability_scope == ["customer_support", "translation"]
      refute Map.has_key?(Map.from_struct(evidence), :score)
      refute Map.has_key?(Map.from_struct(evidence), :rank)
      refute Map.has_key?(Map.from_struct(evidence), :recommendation)

      assert {:ok, %TrustEvidenceResult{} = result} =
               messaging.query_trust_evidence(scope)

      assert result.status == :evidence
      assert result.provider_id == "jido_messaging:stored"
      assert result.evidence == [evidence]
      assert result.outcomes_present == [:succeeded]
      assert TrustEvidenceResult.negative_evidence(result) == []

      assert {:ok, %{status: :no_evidence}} =
               messaging.query_trust_evidence(scope,
                 as_of: DateTime.add(evidence.observed_at, -1, :second)
               )
    end
  end

  test "scope is mandatory, instance-bound, exact, and validates attestation references" do
    records = seed(ETSMessaging, "scope")
    attrs = evidence_attrs(records, "scope", source_id: "missing-message")
    valid_scope = scope!(ETSMessaging, records)

    assert {:error, :trust_evidence_scope_required} =
             ETSMessaging.record_trust_evidence(attrs, nil)

    other_instance_scope = TrustEvidenceScope.new!(SQLiteMessaging, scope_attrs(records))

    assert {:error, :trust_evidence_scope_instance_mismatch} =
             ETSMessaging.record_trust_evidence(attrs, other_instance_scope)

    wrong_scope =
      records
      |> scope_attrs()
      |> Map.put(:room_id, records.other_room.id)
      |> then(&TrustEvidenceScope.new!(ETSMessaging, &1))

    assert {:error, :trust_evidence_scope_violation} =
             ETSMessaging.record_trust_evidence(attrs, wrong_scope)

    assert {:error, :trust_evidence_source_not_found} =
             ETSMessaging.record_trust_evidence(attrs, valid_scope)

    assert {:error, :invalid_trust_evidence_scope} =
             ETSMessaging.trust_evidence_scope(Map.put(scope_attrs(records), :subject_membership_refs, []))

    assert {:error, :invalid_trust_evidence_scope} =
             ETSMessaging.query_trust_evidence(%{valid_scope | requester_authorization_refs: []})
  end

  test "evidence rejects unsafe decision fields, non-Jidoka identity, and self claims" do
    records = seed(ETSMessaging, "strict")
    scope = scope!(ETSMessaging, records)
    attrs = evidence_attrs(records, "strict")

    for unsafe_key <- [
          :score,
          :rank,
          :confidence,
          :recommendation,
          :grant,
          :prompt,
          :output,
          :metadata
        ] do
      assert {:error, :invalid_trust_evidence} =
               ETSMessaging.record_trust_evidence(
                 Map.put(attrs, unsafe_key, %{unsafe: true}),
                 scope
               )
    end

    non_jidoka =
      put_in(attrs, [:subject_jidoka_agent_ref], %{system: :jido, id: "support-agent"})

    assert {:error, :invalid_trust_evidence} =
             ETSMessaging.record_trust_evidence(non_jidoka, scope)

    assert {:error, :invalid_trust_evidence} =
             ETSMessaging.record_trust_evidence(
               Map.put(attrs, :expires_at, DateTime.add(attrs.observed_at, 367, :day)),
               scope
             )

    self_scope =
      records
      |> scope_attrs()
      |> Map.put(:requester_principal_id, records.subject.id)
      |> then(&TrustEvidenceScope.new!(ETSMessaging, &1))

    self_attrs =
      attrs
      |> Map.put(:issuer_principal_id, records.subject.id)
      |> Map.put(:source, provider_source("self-claim"))

    assert {:error, :self_issued_trust_evidence} =
             ETSMessaging.record_trust_evidence(self_attrs, self_scope)
  end

  test "the subject must be an agent and message sources bind room and issuer" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "source")
      scope = scope!(messaging, records)

      wrong_room = evidence_attrs(records, "wrong-room", source_id: records.other_room_message.id)

      assert {:error, :trust_evidence_source_room_violation} =
               messaging.record_trust_evidence(wrong_room, scope)

      wrong_issuer = evidence_attrs(records, "wrong-issuer", source_id: records.other_review_message.id)

      assert {:error, :trust_evidence_source_issuer_violation} =
               messaging.record_trust_evidence(wrong_issuer, scope)

      provider_attrs =
        evidence_attrs(records, "provider", source: provider_source("provider-review"))

      assert {:ok, %TrustEvidence{source: %{kind: :provider_record}}} =
               messaging.record_trust_evidence(provider_attrs, scope)

      human_scope =
        records
        |> scope_attrs()
        |> Map.put(:subject_principal_id, records.other_reviewer.id)
        |> then(&TrustEvidenceScope.new!(messaging, &1))

      human_attrs =
        provider_attrs
        |> Map.put(:subject_principal_id, records.other_reviewer.id)
        |> Map.put(:source, provider_source("human-review"))

      assert {:error, :trust_evidence_subject_not_agent} =
               messaging.record_trust_evidence(human_attrs, human_scope)
    end
  end

  test "exact retries are idempotent and changed data at one source revision conflicts" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "idempotent")
      scope = scope!(messaging, records)
      attrs = evidence_attrs(records, "idempotent")

      assert {:ok, first} = messaging.record_trust_evidence(attrs, scope)
      assert {:ok, ^first} = messaging.record_trust_evidence(attrs, scope)

      changed = Map.put(attrs, :outcome, :failed)
      assert TrustEvidence.new(changed).id == first.id

      assert {:error, :trust_evidence_revision_conflict} =
               messaging.record_trust_evidence(changed, scope)
    end
  end

  test "a higher source revision replaces the query view but preserves history" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "revision")
      scope = scope!(messaging, records)
      first_attrs = evidence_attrs(records, "revision")
      second_attrs = revised(first_attrs, 2, :failed, :disputed, "review:dispute")

      assert {:ok, first} = messaging.record_trust_evidence(first_attrs, scope)
      assert {:ok, second} = messaging.record_trust_evidence(second_attrs, scope)
      assert first.claim_id == second.claim_id
      refute first.id == second.id

      assert {:ok, current} = messaging.query_trust_evidence(scope)
      assert Enum.map(current.evidence, & &1.source.revision) == [2]
      assert current.outcomes_present == [:failed]
      assert TrustEvidenceResult.negative_evidence(current) == [second]

      assert {:ok, history} = messaging.query_trust_evidence(scope, include_history: true)
      assert Enum.map(history.evidence, & &1.source.revision) == [2, 1]
      assert history.outcomes_present == [:failed, :succeeded]
    end
  end

  test "an as-of query selects only source revisions observed by that time" do
    records = seed(ETSMessaging, "as-of-revision")
    scope = scope!(ETSMessaging, records)
    first_observed_at = DateTime.add(DateTime.utc_now(), -120, :second)

    first_attrs =
      evidence_attrs(records, "as-of-revision",
        observed_at: first_observed_at,
        expires_at: DateTime.add(first_observed_at, 3_600, :second)
      )

    second_observed_at = DateTime.add(first_observed_at, 60, :second)

    second_attrs =
      first_attrs
      |> revised(2, :failed, :disputed, "review:as-of-dispute")
      |> Map.put(:observed_at, second_observed_at)
      |> Map.put(:expires_at, DateTime.add(second_observed_at, 3_600, :second))

    assert {:ok, first} = ETSMessaging.record_trust_evidence(first_attrs, scope)
    assert {:ok, second} = ETSMessaging.record_trust_evidence(second_attrs, scope)

    assert TrustEvidence.current_at?(first, first_observed_at)
    refute TrustEvidence.current_at?(first, DateTime.add(first_observed_at, -1, :second))

    assert {:ok, historical} =
             ETSMessaging.query_trust_evidence(scope,
               as_of: DateTime.add(first_observed_at, 30, :second)
             )

    assert historical.evidence == [first]

    assert {:ok, current} = ETSMessaging.query_trust_evidence(scope)
    assert current.evidence == [second]
  end

  test "query results distinguish no evidence, unavailable evidence, and negative evidence" do
    records = seed(ETSMessaging, "states")
    scope = scope!(ETSMessaging, records)

    assert {:ok, %{status: :no_evidence, evidence: [], outcomes_present: []}} =
             ETSMessaging.query_trust_evidence(scope)

    negative_attrs =
      records
      |> evidence_attrs("negative")
      |> Map.put(:outcome, :denied)

    assert {:ok, negative} = ETSMessaging.record_trust_evidence(negative_attrs, scope)

    assert {:ok, %{status: :evidence, outcomes_present: [:denied]} = result} =
             ETSMessaging.query_trust_evidence(scope)

    assert TrustEvidenceResult.negative_evidence(result) == [negative]

    assert {:ok, unavailable} =
             ETSMessaging.query_trust_evidence(scope, provider: UnavailableProvider)

    assert unavailable.status == :unavailable
    assert unavailable.provider_id == "offline_review_service"
    assert unavailable.reason_code == "provider.unavailable"
    assert unavailable.evidence == []
  end

  test "a host-selected provider is scope checked and cannot leak another room" do
    records = seed(ETSMessaging, "provider")
    scope = scope!(ETSMessaging, records)
    valid = TrustEvidence.new(evidence_attrs(records, "provider", source: provider_source("valid")))

    assert {:ok, result} =
             ETSMessaging.query_trust_evidence(scope,
               provider: AvailableProvider,
               provider_opts: [evidence: [valid]]
             )

    assert result.status == :evidence
    assert result.provider_id == "review_service"
    assert result.evidence == [valid]

    leaked =
      records
      |> evidence_attrs("leaked", source: provider_source("leaked"))
      |> Map.put(:room_id, records.other_room.id)
      |> TrustEvidence.new()

    assert {:ok, unavailable} =
             ETSMessaging.query_trust_evidence(scope,
               provider: AvailableProvider,
               provider_opts: [evidence: [leaked]]
             )

    assert unavailable.status == :unavailable
    assert unavailable.reason_code == "provider.invalid_result"
  end

  test "expiry, revocation, and capability filters are explicit query controls" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "filters")
      scope = scope!(messaging, records)
      now = DateTime.utc_now()

      expired =
        evidence_attrs(records, "expired",
          source: provider_source("expired"),
          observed_at: DateTime.add(now, -7_200, :second),
          expires_at: DateTime.add(now, -3_600, :second)
        )

      revoked =
        records
        |> evidence_attrs("revoked", source: provider_source("revoked"))
        |> Map.put(:verification_state, :revoked)
        |> Map.put(:verification_ref, "review:revoked")

      assert {:ok, _expired} = messaging.record_trust_evidence(expired, scope)
      assert {:ok, revoked_evidence} = messaging.record_trust_evidence(revoked, scope)

      assert {:ok, %{status: :no_evidence}} =
               messaging.query_trust_evidence(scope, capability: "missing")

      assert {:ok, default} = messaging.query_trust_evidence(scope)
      assert default.status == :no_evidence

      assert {:ok, with_expired} =
               messaging.query_trust_evidence(scope, include_expired: true)

      assert Enum.map(with_expired.evidence, & &1.source.id) == ["expired"]

      assert {:ok, with_revoked} =
               messaging.query_trust_evidence(scope,
                 verification_states: [:revoked]
               )

      assert with_revoked.evidence == [revoked_evidence]
    end
  end

  test "SQLite keeps evidence across restart" do
    path = sqlite_path("trust-evidence-restart")
    cleanup_sqlite(path)
    on_exit(fn -> cleanup_sqlite(path) end)

    start_supervised!({RestartMessaging, persistence_opts: [path: path]})
    records = seed(RestartMessaging, "restart")
    scope = scope!(RestartMessaging, records)

    assert {:ok, evidence} =
             RestartMessaging.record_trust_evidence(
               evidence_attrs(records, "restart"),
               scope
             )

    :ok = stop_supervised(RestartMessaging)
    start_supervised!({RestartMessaging, persistence_opts: [path: path]})

    assert {:ok, result} = RestartMessaging.query_trust_evidence(scope)
    assert result.evidence == [evidence]
  end

  test "room and participant deletion remove scoped evidence records" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "cleanup")
      scope = scope!(messaging, records)

      assert {:ok, _evidence} =
               messaging.record_trust_evidence(
                 evidence_attrs(records, "cleanup"),
                 scope
               )

      {persistence, state} = Runtime.get_persistence(messaging.__jido_messaging__(:runtime))

      assert :ok = persistence.delete_participant(state, records.reviewer.id)

      assert {:ok, []} =
               persistence.list_trust_evidence(
                 state,
                 records.subject.id,
                 records.room.id,
                 limit: 10
               )

      {:ok, replacement_reviewer} =
        messaging.create_participant(%{
          id: records.reviewer.id,
          type: :human,
          identity: %{name: "Reviewer replacement"}
        })

      records = %{records | reviewer: replacement_reviewer}

      assert {:ok, _evidence} =
               messaging.record_trust_evidence(
                 evidence_attrs(records, "cleanup-room", source: provider_source("cleanup-room")),
                 scope
               )

      assert :ok = messaging.delete_room(records.room.id)

      assert {:ok, []} =
               persistence.list_trust_evidence(
                 state,
                 records.subject.id,
                 records.room.id,
                 limit: 10
               )
    end
  end

  test "concurrent conflicting revisions produce one immutable record" do
    for messaging <- messaging_modules() do
      records = seed(messaging, "concurrent")
      scope = scope!(messaging, records)
      first = evidence_attrs(records, "concurrent")
      second = Map.put(first, :outcome, :failed)

      results =
        [first, second]
        |> Task.async_stream(
          fn attrs -> messaging.record_trust_evidence(attrs, scope) end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %TrustEvidence{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :trust_evidence_revision_conflict}, &1)) == 1
    end
  end

  test "invalid query controls fail without becoming a selection policy" do
    records = seed(ETSMessaging, "query-controls")
    scope = scope!(ETSMessaging, records)

    for opts <- [
          [limit: 0],
          [limit: 101],
          [score: true],
          [provider: "module-name"],
          [verification_states: []],
          [include_expired: :yes],
          [limit: 1, limit: 2]
        ] do
      assert {:error, :invalid_trust_evidence_query} =
               ETSMessaging.query_trust_evidence(scope, opts)
    end
  end

  defp messaging_modules, do: [ETSMessaging, SQLiteMessaging]

  defp seed(messaging, suffix) do
    prefix = messaging |> Module.split() |> List.last() |> String.downcase()
    base = "#{prefix}-#{suffix}"

    {:ok, room} = messaging.create_room(%{id: "#{base}-room", type: :group})
    {:ok, other_room} = messaging.create_room(%{id: "#{base}-other-room", type: :group})

    {:ok, subject} =
      messaging.create_participant(%{
        id: "#{base}-subject",
        type: :agent,
        identity: %{name: "Jidoka Support Agent"}
      })

    {:ok, reviewer} =
      messaging.create_participant(%{
        id: "#{base}-reviewer",
        type: :human,
        identity: %{name: "Reviewer"}
      })

    {:ok, other_reviewer} =
      messaging.create_participant(%{
        id: "#{base}-other-reviewer",
        type: :human,
        identity: %{name: "Other Reviewer"}
      })

    review_message =
      save_message!(messaging, "#{base}-review", room.id, reviewer.id)

    other_review_message =
      save_message!(messaging, "#{base}-other-review", room.id, other_reviewer.id)

    other_room_message =
      save_message!(messaging, "#{base}-other-room-review", other_room.id, reviewer.id)

    %{
      room: room,
      other_room: other_room,
      subject: subject,
      reviewer: reviewer,
      other_reviewer: other_reviewer,
      review_message: review_message,
      other_review_message: other_review_message,
      other_room_message: other_room_message
    }
  end

  defp save_message!(messaging, id, room_id, sender_id) do
    {:ok, message} =
      messaging.save_message(%{
        id: id,
        room_id: room_id,
        sender_id: sender_id,
        role: :user,
        content: [%Text{text: "Reviewed outcome"}],
        status: :sent
      })

    message
  end

  defp scope!(messaging, records) do
    {:ok, scope} = messaging.trust_evidence_scope(scope_attrs(records))
    scope
  end

  defp scope_attrs(records) do
    %{
      room_id: records.room.id,
      requester_principal_id: records.reviewer.id,
      subject_principal_id: records.subject.id,
      subject_jidoka_agent_ref: %{system: :jidoka, id: "support-agent"},
      requester_authorization_refs: ["grant:reviewer:room"],
      subject_membership_refs: ["membership:support-agent:room"]
    }
  end

  defp evidence_attrs(records, suffix, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(observed_at, 86_400, :second))

    source =
      Keyword.get(opts, :source, %{
        kind: :message,
        id: Keyword.get(opts, :source_id, records.review_message.id),
        revision: 1
      })

    %{
      room_id: records.room.id,
      subject_principal_id: records.subject.id,
      subject_jidoka_agent_ref: %{system: :jidoka, id: "support-agent"},
      issuer_principal_id: records.reviewer.id,
      capability_scope: ["translation", "customer_support"],
      outcome: :succeeded,
      source: source,
      verification_state: :verified,
      verification_ref: "review:#{suffix}",
      observed_at: observed_at,
      expires_at: expires_at
    }
  end

  defp provider_source(id) do
    %{
      kind: :provider_record,
      provider_id: "review_service",
      id: id,
      revision: 1
    }
  end

  defp revised(attrs, revision, outcome, verification_state, verification_ref) do
    attrs
    |> put_in([:source, :revision], revision)
    |> Map.put(:outcome, outcome)
    |> Map.put(:verification_state, verification_state)
    |> Map.put(:verification_ref, verification_ref)
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
