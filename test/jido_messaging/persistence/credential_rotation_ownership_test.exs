defmodule Jido.Messaging.Persistence.CredentialRotationOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{IdentityCredential, Persistence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} credential storage keeps immutable proof identity and terminal lifecycle" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      original = credential("original")

      assert {:error, {:invalid_initial_revision, 2}} =
               adapter.save_identity_credential(state, %{original | revision: 2})

      assert {:error, {:invalid_initial_status, :suspended}} =
               adapter.save_identity_credential(state, %{original | status: :suspended})

      assert {:ok, ^original} = adapter.save_identity_credential(state, original)
      assert {:ok, ^original} = adapter.save_identity_credential(state, original)

      for field <- [:subject_principal_id, :provider_id, :proof_ref, :key_version_ref] do
        changed = original |> Map.put(field, "foreign") |> Map.put(:revision, 2)
        assert {:error, :identity_credential_identity_immutable} = adapter.save_identity_credential(state, changed)
      end

      suspended = IdentityCredential.transition(original, :suspended)
      assert {:ok, ^suspended} = adapter.save_identity_credential(state, suspended)
      assert {:error, {:stale_revision, 2}} = adapter.save_identity_credential(state, original)
      revoked = IdentityCredential.transition(suspended, :revoked, reason: "closed")
      assert {:ok, ^revoked} = adapter.save_identity_credential(state, revoked)
      assert {:ok, ^revoked} = adapter.save_identity_credential(state, revoked)

      assert {:error, :identity_credential_revocation_terminal} =
               adapter.save_identity_credential(state, %{revoked | status: :active, revision: 4})

      assert {:ok, [^revoked]} =
               adapter.list_identity_credentials(state, "subject", status: :revoked, provider_id: "fixture")

      assert {:ok, []} = adapter.list_identity_credentials(state, "foreign")
      assert {:ok, []} = adapter.list_identity_credentials(state, "subject", provider_id: "foreign")
    end

    test "#{adapter} rotation rejects wrong lineage or scope without replacing either record" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      original = credential("original")
      assert {:ok, ^original} = adapter.save_identity_credential(state, original)
      revoked = IdentityCredential.transition(original, :revoked, reason: "rotate")
      replacement = %{credential("replacement") | rotated_from_credential_id: original.id}

      for {old, next, expected} <- [
            {%{original | revision: 2}, replacement, :identity_rotation_requires_revocation},
            {revoked, %{replacement | status: :suspended}, :invalid_identity_rotation_replacement},
            {revoked, %{replacement | revision: 2}, :invalid_identity_rotation_replacement},
            {revoked, %{replacement | rotated_from_credential_id: "foreign"}, :invalid_identity_rotation_lineage},
            {revoked, %{replacement | subject_principal_id: "foreign"}, :identity_credential_identity_immutable}
          ] do
        assert {:error, ^expected} = adapter.rotate_identity_credential(state, old, next)
        assert {:ok, ^original} = adapter.get_identity_credential(state, original.id)
        assert {:error, :not_found} = adapter.get_identity_credential(state, replacement.id)
      end

      assert {:ok, ^revoked, ^replacement} = adapter.rotate_identity_credential(state, revoked, replacement)
      assert {:ok, ^revoked} = adapter.get_identity_credential(state, original.id)
      assert {:ok, ^replacement} = adapter.get_identity_credential(state, replacement.id)
      assert {:ok, [^replacement]} = adapter.list_identity_credentials(state, "subject", status: :active, limit: 1)
    end
  end

  defp credential(id) do
    IdentityCredential.new(%{
      id: id,
      issuer_principal_id: "issuer",
      subject_principal_id: "subject",
      provider_id: "fixture",
      proof_type: "opaque",
      proof_ref: "proof:" <> id,
      key_version_ref: "key:one",
      conditions: %{audience: "fixture", room_ids: ["room"]},
      issued_at: ~U[2026-10-13 05:00:00Z],
      not_before: ~U[2026-10-13 05:00:00Z],
      expires_at: ~U[2026-10-14 05:00:00Z]
    })
  end
end
