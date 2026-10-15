defmodule Jido.Messaging.IdentityFacadeDefaultsTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging

  defmodule ETSInstance do
    use Messaging, persistence: Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule SQLiteInstance do
    use Messaging, persistence: Messaging.Persistence.SQLite, runtime_profile: :core
  end

  setup do
    path = Path.join(System.tmp_dir!(), "identity-facade-#{System.unique_integer([:positive])}.sqlite3")
    start_supervised!(ETSInstance)
    start_supervised!({SQLiteInstance, persistence_opts: [path: path]})
    on_exit(fn -> File.rm(path) end)
    {:ok, instances: [ETSInstance, SQLiteInstance]}
  end

  test "root credential defaults retain records and terminal revocation without authorization", context do
    for instance <- context.instances do
      runtime = instance.__jido_messaging__(:runtime)
      {issuer, subject, room} = seed(runtime)
      assert {:ok, credential} = Messaging.create_identity_credential(runtime, credential_attrs(issuer, subject, room))
      assert {:ok, ^credential} = Messaging.get_identity_credential(runtime, credential.id)
      assert {:ok, [^credential]} = Messaging.list_identity_credentials(runtime, subject.id)
      assert {:ok, suspended} = Messaging.suspend_identity_credential(runtime, credential.id, 1)
      assert suspended.status == :suspended
      assert {:ok, active} = Messaging.activate_identity_credential(runtime, credential.id, 2)
      assert active.revision == 3
      assert {:ok, revoked} = Messaging.revoke_identity_credential(runtime, credential.id, 3)
      assert revoked.status == :revoked
      assert revoked.revision == 4

      assert {:error, :identity_credential_revocation_terminal} =
               Messaging.activate_identity_credential(runtime, credential.id, 4)

      assert {:ok, [^revoked]} = Messaging.list_identity_credentials(runtime, subject.id)
      assert_no_communication(instance, subject.id, room.id)
    end
  end

  test "root principal and binding defaults preserve provider scope and inactive denial", context do
    for instance <- context.instances do
      runtime = instance.__jido_messaging__(:runtime)
      {_issuer, subject, room} = seed(runtime)
      assert {:ok, principal} = Messaging.create_principal(runtime, %{participant_id: subject.id, type: :agent})
      assert principal.id == subject.id
      assert {:ok, ^principal} = Messaging.get_principal(runtime, subject.id)
      assert {:ok, binding} = Messaging.bind_external_identity(runtime, principal.id, :test, "owned", "provider-user")
      assert binding.assurance == :asserted
      assert {:ok, [^binding]} = Messaging.list_external_identity_bindings(runtime, principal.id)
      assert {:ok, ^binding} = Messaging.get_external_identity_binding(runtime, :test, "owned", "provider-user")
      assert {:error, :not_found} = Messaging.get_external_identity_binding(runtime, :test, "foreign", "provider-user")
      assert {:ok, revoked} = Messaging.revoke_external_identity_binding(runtime, binding.id)
      assert revoked.status == :revoked

      assert {:error, :external_identity_revoked} =
               Messaging.bind_external_identity(runtime, principal.id, :test, "owned", "provider-user")

      assert {:ok, _} = Messaging.save_principal(runtime, %{principal | status: :suspended})

      assert {:error, {:principal_inactive, :suspended}} =
               Messaging.bind_external_identity(runtime, principal.id, :test, "owned", "other-user")

      assert_no_communication(instance, subject.id, room.id)
    end
  end

  test "root optional identity and proof defaults cannot promote unverified input", context do
    for instance <- context.instances do
      runtime = instance.__jido_messaging__(:runtime)
      {issuer, subject, room} = seed(runtime)

      request_context = %{
        subject_principal_id: subject.id,
        controller_principal_id: issuer.id,
        audience: "fixture",
        room_id: room.id
      }

      assert {:ok, evidence} = Messaging.verify_optional_identity(runtime, nil, %{}, request_context)
      assert evidence.assurance == :uncredentialed
      assert {:ok, credential} = Messaging.create_identity_credential(runtime, credential_attrs(issuer, subject, room))

      proof = %{
        assertion_id: "default-proof",
        proof_type: credential.proof_type,
        proof_ref: credential.proof_ref,
        issued_at: DateTime.utc_now()
      }

      assert {:error, :identity_provider_unavailable} =
               Messaging.verify_identity_credential(runtime, credential.id, proof, request_context)

      assert {:error, :identity_provider_unavailable} =
               Messaging.verify_optional_identity(runtime, credential.id, proof, request_context)

      assert {:ok, ^credential} = Messaging.get_identity_credential(runtime, credential.id)
      assert_no_communication(instance, subject.id, room.id)
    end
  end

  defp seed(runtime) do
    {:ok, issuer} = Messaging.create_participant(runtime, %{id: "issuer", type: :human})
    {:ok, subject} = Messaging.create_participant(runtime, %{id: "subject", type: :agent})
    {:ok, room} = Messaging.create_room(runtime, %{id: "identity-room", type: :group})
    {issuer, subject, room}
  end

  defp credential_attrs(issuer, subject, room) do
    now = DateTime.utc_now()

    %{
      id: "credential",
      issuer_principal_id: issuer.id,
      subject_principal_id: subject.id,
      provider_id: "fixture",
      proof_type: "opaque",
      proof_ref: "proof:complete",
      conditions: %{audience: "fixture", room_ids: [room.id]},
      issued_at: now,
      not_before: now,
      expires_at: DateTime.add(now, 3_600, :second),
      metadata: %{complete: "all data"}
    }
  end

  defp assert_no_communication(instance, subject, room) do
    assert Jido.Messaging.TestHelpers.runtime_entry_count(instance.__jido_messaging__(:runtime)) == 0
    assert instance.count_agents() == 0
    assert {:ok, []} = instance.list_principal_grants(subject)
    assert {:ok, []} = instance.list_memberships(room)
    assert {:ok, []} = instance.list_messages(room)
  end
end
