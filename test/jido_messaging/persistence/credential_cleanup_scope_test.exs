defmodule Jido.Messaging.Persistence.CredentialCleanupScopeTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.Participant
  alias Jido.Messaging.{IdentityCredential, Persistence, Principal}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} participant deletion removes subject and issuer credentials with only their replay markers" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      for id <- ["owned", "foreign", "issuer"] do
        participant = Participant.new(%{id: id, type: :human})
        principal = Principal.from_participant(participant)
        assert {:ok, ^participant} = adapter.save_participant(state, participant)
        assert {:ok, ^principal} = adapter.save_principal(state, principal)
      end

      subject = credential("subject", "issuer", "owned")
      issuer = credential("issued", "owned", "foreign")
      foreign = credential("foreign", "issuer", "foreign")
      expiry = DateTime.add(DateTime.utc_now(), 3_600, :second)

      for record <- [subject, issuer, foreign] do
        assert {:ok, ^record} = adapter.save_identity_credential(state, record)
        assert :ok = adapter.consume_identity_assertion(state, record.id, assertion(record), expiry)

        assert {:error, :identity_assertion_replayed} =
                 adapter.consume_identity_assertion(state, record.id, assertion(record), expiry)
      end

      assert :ok = adapter.delete_participant(state, "owned")
      assert {:error, :not_found} = adapter.get_participant(state, "owned")
      assert {:error, :not_found} = adapter.get_principal(state, "owned")
      assert {:error, :not_found} = adapter.get_identity_credential(state, subject.id)
      assert {:error, :not_found} = adapter.get_identity_credential(state, issuer.id)
      assert {:ok, ^foreign} = adapter.get_identity_credential(state, foreign.id)
      assert {:ok, []} = adapter.list_identity_credentials(state, "owned")
      assert {:ok, [^foreign]} = adapter.list_identity_credentials(state, "foreign")

      assert {:error, :identity_assertion_replayed} =
               adapter.consume_identity_assertion(state, foreign.id, assertion(foreign), expiry)

      # The backend primitive verifies cleanup without claiming authorization to recreate a credential.
      for deleted <- [subject, issuer] do
        assert :ok = adapter.consume_identity_assertion(state, deleted.id, assertion(deleted), expiry)

        assert {:error, :identity_assertion_replayed} =
                 adapter.consume_identity_assertion(state, deleted.id, assertion(deleted), expiry)
      end

      assert {:ok, foreign_participant} = adapter.get_participant(state, "foreign")
      assert foreign_participant.id == "foreign"
      assert {:ok, foreign_principal} = adapter.get_principal(state, "foreign")
      assert foreign_principal.participant_id == "foreign"
      assert :ok = adapter.delete_participant(state, "absent")
      assert {:ok, ^foreign} = adapter.get_identity_credential(state, foreign.id)
    end

    test "#{adapter} expired replay marker permits one complete replacement without changing another marker" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      future = DateTime.add(DateTime.utc_now(), 3_600, :second)
      assert :ok = adapter.consume_identity_assertion(state, "expired", "expired-marker", past)
      assert :ok = adapter.consume_identity_assertion(state, "foreign", "foreign-marker", future)
      assert :ok = adapter.consume_identity_assertion(state, "expired", "expired-marker", future)

      assert {:error, :identity_assertion_replayed} =
               adapter.consume_identity_assertion(state, "expired", "expired-marker", future)

      assert {:error, :identity_assertion_replayed} =
               adapter.consume_identity_assertion(state, "foreign", "foreign-marker", future)
    end
  end

  defp credential(id, issuer, subject) do
    now = DateTime.utc_now()

    IdentityCredential.new(%{
      id: id,
      issuer_principal_id: issuer,
      subject_principal_id: subject,
      provider_id: "fixture",
      proof_type: "opaque",
      proof_ref: "proof:" <> id,
      conditions: %{audience: "fixture", room_ids: ["room"]},
      issued_at: now,
      not_before: now,
      expires_at: DateTime.add(now, 3_600, :second),
      metadata: %{complete: id}
    })
  end

  defp assertion(record), do: "marker:" <> record.id
end
