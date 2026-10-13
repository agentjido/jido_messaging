defmodule Jido.Messaging.CheckpointIdentityEventContractTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{
    ActivityPage,
    Events,
    ExternalIdentityBinding,
    HistoryScope,
    IdentityCredential,
    Message,
    MessagingActivityEntry
  }

  test "legacy identities keep stable bridge scope and cannot merge another principal" do
    input = %{
      "participant_id" => "person",
      "channel" => "slack",
      "bridge_id" => "owned",
      "external_id" => "provider-id"
    }

    binding = ExternalIdentityBinding.from_legacy(input)
    assert binding.principal_id == "person"
    assert binding.assurance == :asserted
    assert binding.inserted_at == ~U[1970-01-01 00:00:00Z]
    assert ExternalIdentityBinding.from_legacy(input) == binding
    foreign = ExternalIdentityBinding.from_legacy(Map.put(input, "bridge_id", "foreign"))
    assert foreign.id != binding.id
    assert_raise ArgumentError, fn -> ExternalIdentityBinding.strengthen(binding, foreign) end

    assert ExternalIdentityBinding.assurance_levels() == [
             :asserted,
             :provider_verified,
             :application_verified,
             :cryptographically_verified
           ]

    proof = %{binding | proof_ref: "opaque-proof"}
    strengthened = ExternalIdentityBinding.strengthen(binding, proof)
    assert strengthened.proof_ref == "opaque-proof"
    assert strengthened.assurance == :asserted
    assert strengthened.verified_at == binding.verified_at

    assert_raise ArgumentError, fn ->
      ExternalIdentityBinding.new(%{
        principal_id: "person",
        participant_id: "person",
        channel: nil,
        bridge_id: "owned",
        external_id: "provider-id"
      })
    end
  end

  defp credential_attrs do
    %{
      issuer_principal_id: "issuer",
      subject_principal_id: "subject",
      provider_id: "fixture",
      proof_type: "opaque",
      proof_ref: "proof-ref",
      conditions: %{audience: "fixture", room_ids: ["room"]},
      issued_at: ~U[2026-10-13 12:00:00Z],
      expires_at: ~U[2026-10-13 13:00:00Z]
    }
  end

  test "credential validity and principal conditions reject unsafe lifecycle input" do
    invalid = [
      %{revision: 0},
      %{not_before: ~U[2026-10-13 11:00:00Z]},
      %{expires_at: ~U[2026-10-13 12:00:00Z]},
      %{issued_at: "invalid"},
      %{issuer_principal_id: "subject"},
      %{status: :revoked},
      %{revoked_at: ~U[2026-10-13 12:00:00Z]},
      %{purpose: :unknown},
      %{status: :unknown}
    ]

    for overrides <- invalid do
      assert_raise ArgumentError, fn -> IdentityCredential.new(Map.merge(credential_attrs(), overrides)) end
    end

    for status <- ["active", "suspended", "revoked"] do
      overrides = %{status: status, purpose: "controller"}
      overrides = if status == "revoked", do: Map.put(overrides, :revoked_at, ~U[2026-10-13 12:30:00Z]), else: overrides
      credential = IdentityCredential.new(Map.merge(credential_attrs(), overrides))
      assert Atom.to_string(credential.status) == status
      assert {:ok, ^credential} = Zoi.parse(IdentityCredential.schema(), credential)
    end
  end

  test "credential transitions cannot revive revocation or skip a validity condition" do
    credential = IdentityCredential.new(credential_attrs())
    assert_raise ArgumentError, fn -> IdentityCredential.transition(credential, :suspended, changed_at: :invalid) end
    assert_raise ArgumentError, fn -> IdentityCredential.transition(credential, :active) end
    revoked = IdentityCredential.transition(credential, :revoked, changed_at: ~U[2026-10-13 12:30:00Z])
    assert_raise ArgumentError, fn -> IdentityCredential.transition(revoked, :active) end
    refute IdentityCredential.active_at?(revoked, ~U[2026-10-13 12:45:00Z])
    refute IdentityCredential.active_at?(credential, ~U[2026-10-13 11:59:59Z])
    refute IdentityCredential.active_at?(credential, credential.expires_at)
    assert IdentityCredential.active_at?(credential, ~U[2026-10-13 12:30:00Z])
  end

  test "default event builders preserve complete canonical content and redact private failure reasons" do
    message =
      Message.new(%{
        room_id: "room",
        sender_id: "person",
        role: :user,
        content: [%{type: :text, text: "complete Unicode 👋 content"}]
      })

    for function <- [:message_received, :message_sent] do
      assert {:ok, fact} = apply(Events, function, [__MODULE__, message])
      assert fact.data["message_id"] == message.id
      assert fact.data["text"] == "complete Unicode 👋 content"
      assert {:ok, ^fact} = fact |> Jido.Signal.to_map() |> Jido.Signal.from_map()
    end

    for function <- [:reaction_added, :reaction_removed] do
      assert {:ok, fact} = apply(Events, function, [__MODULE__, message, "person", "👍"])
      assert fact.data["reaction"] == "👍"
      assert fact.data["message_id"] == message.id
    end

    assert {:ok, failed} = Events.message_failed(__MODULE__, "room", {:private, "fixture-secret"})
    refute Jason.encode!(Jido.Signal.to_map(failed)) =~ "fixture-secret"
    assert failed.type == "jido.messaging.message.failed"
  end

  test "native wire event names retain their established observation telemetry" do
    entries = [
      {"message.sent", [:message, :sent]},
      {"message.failed", [:message, :failed]},
      {"room.message_added", [:room, :message_added]},
      {"room.created", [:room, :created]},
      {"room.participant_joined", [:room, :participant_joined]},
      {"room.participant_left", [:room, :participant_left]},
      {"participant.typing", [:participant, :typing]},
      {"message.reaction_added", [:message, :reaction_added]},
      {"message.reaction_removed", [:message, :reaction_removed]},
      {"message.delivered", [:message, :delivered]},
      {"message.read", [:message, :read]},
      {"thread.created", [:thread, :created]},
      {"thread.reply_added", [:thread, :reply_added]}
    ]

    for {type, suffix} <- entries do
      assert Events.telemetry_event_for("jido.messaging." <> type) == [:jido_messaging | suffix]
    end

    assert Events.telemetry_event_for(:custom) == [:jido_messaging, :room, :custom]
  end

  test "activity cursors retain complete order and reject conflicting or foreign cursors" do
    entries =
      for id <- ["a", "b", "c"] do
        MessagingActivityEntry.new(%{
          principal_id: "agent",
          room_id: "room",
          kind: :request,
          status: :running,
          summary: %{outcome: :none, code: "request.running"},
          execution_ref: %{
            integration_id: "fixture",
            session_id: "session-" <> id,
            request_id: "request-" <> id,
            detail_availability: :unavailable
          },
          source_event_id: "event-" <> id,
          source_event_type: "jidoka.request.started",
          source_revision: 1,
          source_recorded_at: ~U[2026-10-13 12:00:00Z]
        })
      end

    [first, second, third] = Enum.sort_by(entries, & &1.id)
    assert {:ok, [^first]} = ActivityPage.paginate(Enum.reverse(entries), before: second.id)
    assert {:ok, [^third]} = ActivityPage.paginate(Enum.reverse(entries), after: second.id)
    assert {:error, :cursor_not_found} = ActivityPage.paginate(entries, before: "foreign")
    assert {:error, :invalid_cursor_options} = ActivityPage.paginate(entries, before: first.id, after: third.id)
    assert HistoryScope.new!(__MODULE__, ["room", "room"]).room_ids == ["room"]
    assert_raise ArgumentError, fn -> HistoryScope.new!(__MODULE__, [:invalid]) end
  end
end
