defmodule Jido.Messaging.IdentityCredentialsTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Chat.{Participant, Room}

  alias Jido.Messaging.{
    IdentityCredential,
    IdentityEvidence,
    Message,
    Persistence
  }

  defmodule CredentialMessaging do
    use Jido.Messaging
  end

  defmodule TestProvider do
    @behaviour Jido.Messaging.IdentityProvider

    @impl true
    def verify(credential, proof, context, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:identity_provider_called, credential.id, proof, context})
      end

      if Map.get(proof, :valid, Map.get(proof, "valid", false)) do
        {:ok,
         %{
           assurance: :verified,
           key_version_ref: credential.key_version_ref,
           metadata: %{verification_system: "test-provider"}
         }}
      else
        {:error, :invalid_proof}
      end
    end
  end

  defmodule SlowProvider do
    @behaviour Jido.Messaging.IdentityProvider

    @impl true
    def verify(_credential, _proof, _context, opts) do
      Process.sleep(Keyword.get(opts, :delay, 100))
      {:ok, %{assurance: :verified}}
    end
  end

  defmodule RaisingProvider do
    @behaviour Jido.Messaging.IdentityProvider

    @impl true
    def verify(_credential, _proof, _context, _opts), do: raise("provider failed")
  end

  defmodule WrongKeyProvider do
    @behaviour Jido.Messaging.IdentityProvider

    @impl true
    def verify(_credential, _proof, _context, _opts) do
      {:ok, %{assurance: :verified, key_version_ref: "key:wrong"}}
    end
  end

  for adapter <- [Persistence.ETS, Persistence.SQLite] do
    test "#{inspect(adapter)} verifies, records replay, and keeps authorship separate" do
      with_runtime(unquote(adapter), fn messaging ->
        %{agent: agent, controller: controller, room: room} = create_identity_scope(messaging)
        {:ok, credential} = messaging.create_identity_credential(credential_attrs(agent, controller, room))
        proof = proof(credential, "assertion:one")
        context = context(agent, controller, room)

        assert {:ok, evidence} =
                 messaging.verify_identity_credential(credential.id, proof, context,
                   provider: TestProvider,
                   test_pid: self()
                 )

        assert evidence.assurance == :verified
        assert evidence.subject_principal_id == agent.id
        assert evidence.controller_principal_id == controller.id
        assert evidence.credential_revision == 1

        assert_receive {:identity_provider_called, credential_id, transient_proof, ^context}
        assert credential_id == credential.id
        assert transient_proof.raw_proof == "not-persisted"

        message =
          Message.new(%{
            room_id: room.id,
            sender_id: agent.id,
            role: :assistant,
            content: [%{type: :text, text: "Agent result"}]
          })

        assert {:ok, annotated} = IdentityEvidence.annotate_message(message, evidence)
        assert annotated.sender_id == agent.id
        assert annotated.metadata.identity_evidence.authored_by_principal_id == agent.id
        assert annotated.metadata.identity_evidence.controller_principal_id == controller.id
        refute Map.has_key?(annotated.metadata.identity_evidence, :authorization)

        assert {:ok, persisted} =
                 Jido.Messaging.save_message_struct(
                   messaging.__jido_messaging__(:runtime),
                   annotated
                 )

        assert {:ok, reloaded} = messaging.get_message(persisted.id)
        assert reloaded.sender_id == agent.id
        assert reloaded.metadata.identity_evidence.authored_by_principal_id == agent.id

        assert {:error, :identity_assertion_replayed} =
                 messaging.verify_identity_credential(credential.id, proof, context, provider: TestProvider)
      end)
    end

    test "#{inspect(adapter)} enforces scope, lifecycle, and expected revisions" do
      with_runtime(unquote(adapter), fn messaging ->
        %{agent: agent, controller: controller, room: room} = create_identity_scope(messaging)
        {:ok, other_room} = messaging.create_room(%{type: :group, name: "Other"})
        {:ok, credential} = messaging.create_identity_credential(credential_attrs(agent, controller, room))

        assert {:error, :identity_credential_audience_mismatch} =
                 messaging.verify_identity_credential(
                   credential.id,
                   proof(credential, "assertion:audience"),
                   %{context(agent, controller, room) | audience: "other"},
                   provider: TestProvider
                 )

        assert {:error, :identity_credential_room_mismatch} =
                 messaging.verify_identity_credential(
                   credential.id,
                   proof(credential, "assertion:room"),
                   %{context(agent, controller, room) | room_id: other_room.id},
                   provider: TestProvider
                 )

        assert {:ok, suspended} = messaging.suspend_identity_credential(credential.id, 1)
        assert suspended.status == :suspended
        assert suspended.revision == 2

        assert {:error, {:stale_revision, 2}} =
                 messaging.activate_identity_credential(credential.id, 1)

        assert {:ok, active} = messaging.activate_identity_credential(credential.id, 2)
        assert active.status == :active

        assert {:ok, revoked} =
                 messaging.revoke_identity_credential(credential.id, 3, reason: "controller request")

        assert revoked.status == :revoked
        assert revoked.revocation_reason == "controller request"

        assert {:error, :identity_credential_inactive} =
                 messaging.verify_identity_credential(
                   credential.id,
                   proof(credential, "assertion:revoked"),
                   context(agent, controller, room),
                   provider: TestProvider
                 )

        assert {:error, :identity_credential_revocation_terminal} =
                 messaging.activate_identity_credential(credential.id, 4)
      end)
    end

    test "#{inspect(adapter)} rotates proof material without changing the principal relation" do
      with_runtime(unquote(adapter), fn messaging ->
        %{agent: agent, controller: controller, room: room} = create_identity_scope(messaging)
        {:ok, old} = messaging.create_identity_credential(credential_attrs(agent, controller, room))

        replacement_attrs = %{
          id: "credential:replacement",
          provider_id: "provider:test",
          proof_type: "test-signature-v2",
          proof_ref: "proof:replacement",
          key_version_ref: "key:v2",
          expires_at: DateTime.add(DateTime.utc_now(), 7_200, :second)
        }

        assert {:ok, %{revoked: revoked, credential: replacement}} =
                 messaging.rotate_identity_credential(old.id, 1, replacement_attrs)

        assert revoked.status == :revoked
        assert revoked.revision == 2
        assert replacement.status == :active
        assert replacement.revision == 1
        assert replacement.rotated_from_credential_id == old.id
        assert replacement.issuer_principal_id == controller.id
        assert replacement.subject_principal_id == agent.id
        assert replacement.conditions == old.conditions

        assert {:error, :identity_credential_inactive} =
                 messaging.verify_identity_credential(
                   old.id,
                   proof(old, "assertion:old"),
                   context(agent, controller, room),
                   provider: TestProvider
                 )

        assert {:ok, evidence} =
                 messaging.verify_identity_credential(
                   replacement.id,
                   proof(replacement, "assertion:new"),
                   context(agent, controller, room),
                   provider: TestProvider
                 )

        assert evidence.key_version_ref == "key:v2"
        assert {:ok, [^revoked, ^replacement]} = messaging.list_identity_credentials(agent.id)
      end)
    end
  end

  test "optional identity returns bounded lower assurance and still checks message authorship" do
    with_runtime(Persistence.ETS, fn messaging ->
      %{agent: agent, room: room} = create_identity_scope(messaging)

      assert {:ok, evidence} =
               messaging.verify_optional_identity(nil, %{}, %{
                 subject_principal_id: agent.id,
                 audience: "jidoka:test",
                 room_id: room.id
               })

      assert evidence.assurance == :uncredentialed
      assert evidence.controller_principal_id == nil
      assert DateTime.diff(evidence.valid_until, evidence.verified_at, :millisecond) <= 300_000

      other_message =
        Message.new(%{
          room_id: room.id,
          sender_id: "principal:other",
          role: :assistant,
          content: []
        })

      assert {:error, :identity_evidence_subject_mismatch} =
               IdentityEvidence.annotate_message(other_message, evidence)
    end)
  end

  test "provider failures do not consume the assertion" do
    with_runtime(Persistence.ETS, fn messaging ->
      %{agent: agent, controller: controller, room: room} = create_identity_scope(messaging)
      {:ok, credential} = messaging.create_identity_credential(credential_attrs(agent, controller, room))
      assertion = proof(credential, "assertion:retry")
      identity_context = context(agent, controller, room)

      assert {:error, :identity_provider_timeout} =
               messaging.verify_identity_credential(
                 credential.id,
                 assertion,
                 identity_context,
                 provider: SlowProvider,
                 timeout: 10,
                 delay: 100
               )

      assert {:error, {:provider_exception, RuntimeError}} =
               messaging.verify_identity_credential(
                 credential.id,
                 assertion,
                 identity_context,
                 provider: RaisingProvider
               )

      assert {:ok, _evidence} =
               messaging.verify_identity_credential(
                 credential.id,
                 assertion,
                 identity_context,
                 provider: TestProvider
               )
    end)
  end

  test "proof references, timestamps, and key versions are checked" do
    with_runtime(Persistence.ETS, fn messaging ->
      %{agent: agent, controller: controller, room: room} = create_identity_scope(messaging)
      issued_at = DateTime.add(DateTime.utc_now(), -600, :second)

      {:ok, credential} =
        messaging.create_identity_credential(credential_attrs(agent, controller, room, issued_at))

      identity_context = context(agent, controller, room)

      assert {:error, :identity_proof_reference_mismatch} =
               messaging.verify_identity_credential(
                 credential.id,
                 %{proof(credential, "assertion:wrong-ref") | proof_ref: "proof:wrong"},
                 identity_context,
                 provider: TestProvider,
                 test_pid: self()
               )

      refute_receive {:identity_provider_called, _, _, _}

      old_proof =
        credential
        |> proof("assertion:old")
        |> Map.put(:issued_at, DateTime.add(DateTime.utc_now(), -301, :second))

      assert {:error, :identity_assertion_too_old} =
               messaging.verify_identity_credential(
                 credential.id,
                 old_proof,
                 identity_context,
                 provider: TestProvider
               )

      future_proof =
        credential
        |> proof("assertion:future")
        |> Map.put(:issued_at, DateTime.add(DateTime.utc_now(), 31, :second))

      assert {:error, :identity_assertion_from_future} =
               messaging.verify_identity_credential(
                 credential.id,
                 future_proof,
                 identity_context,
                 provider: TestProvider
               )

      assert {:error, :identity_key_version_mismatch} =
               messaging.verify_identity_credential(
                 credential.id,
                 proof(credential, "assertion:key"),
                 identity_context,
                 provider: WrongKeyProvider
               )
    end)
  end

  test "one concurrent assertion use succeeds" do
    for adapter <- [Persistence.ETS, Persistence.SQLite] do
      with_runtime(adapter, fn messaging ->
        %{agent: agent, controller: controller, room: room} = create_identity_scope(messaging)
        {:ok, credential} = messaging.create_identity_credential(credential_attrs(agent, controller, room))
        assertion = proof(credential, "assertion:race")
        identity_context = context(agent, controller, room)

        results =
          1..20
          |> Task.async_stream(
            fn _index ->
              messaging.verify_identity_credential(
                credential.id,
                assertion,
                identity_context,
                provider: TestProvider
              )
            end,
            max_concurrency: 20,
            ordered: false
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &match?({:ok, %IdentityEvidence{}}, &1)) == 1
        assert Enum.count(results, &match?({:error, :identity_assertion_replayed}, &1)) == 19
      end)
    end
  end

  test "SQLite credentials and replay records survive an adapter restart" do
    path = tmp_path("identity-restart")
    {:ok, state} = Persistence.SQLite.init(path: path)
    now = DateTime.utc_now()
    controller = Participant.new(%{id: "principal:controller", type: :human})
    agent = Participant.new(%{id: "principal:agent", type: :agent})
    room = Room.new(%{id: "room:identity", type: :group})
    credential = IdentityCredential.new(credential_attrs(agent, controller, room, now))

    assert {:ok, ^controller} = Persistence.SQLite.save_participant(state, controller)
    assert {:ok, ^agent} = Persistence.SQLite.save_participant(state, agent)
    assert {:ok, ^room} = Persistence.SQLite.save_room(state, room)
    assert {:ok, ^credential} = Persistence.SQLite.save_identity_credential(state, credential)

    assert :ok =
             Persistence.SQLite.consume_identity_assertion(
               state,
               credential.id,
               "hashed-assertion",
               credential.expires_at
             )

    :ok = Sqlite3.close(state.db)
    {:ok, restarted} = Persistence.SQLite.init(path: path)

    assert {:ok, ^credential} = Persistence.SQLite.get_identity_credential(restarted, credential.id)

    assert {:error, :identity_assertion_replayed} =
             Persistence.SQLite.consume_identity_assertion(
               restarted,
               credential.id,
               "hashed-assertion",
               credential.expires_at
             )

    :ok = Sqlite3.close(restarted.db)
  end

  test "raw keys and secrets cannot enter a credential record" do
    now = DateTime.utc_now()

    assert_raise ArgumentError, fn ->
      IdentityCredential.new(%{
        issuer_principal_id: "principal:controller",
        subject_principal_id: "principal:agent",
        conditions: %{audience: "jidoka:test", room_ids: ["room:one"]},
        provider_id: "provider:test",
        proof_type: "test-signature",
        proof_ref: "proof:test",
        expires_at: DateTime.add(now, 3_600, :second),
        private_key: "must-not-persist"
      })
    end

    assert_raise ArgumentError, fn ->
      IdentityCredential.new(%{
        issuer_principal_id: "principal:controller",
        subject_principal_id: "principal:agent",
        conditions: %{audience: "jidoka:test", room_ids: ["room:one"]},
        provider_id: "provider:test",
        proof_type: "test-signature",
        proof_ref: "proof:test",
        expires_at: DateTime.add(now, 3_600, :second),
        metadata: %{access_token: "must-not-persist"}
      })
    end

    assert_raise ArgumentError, fn ->
      IdentityCredential.new(%{
        issuer_principal_id: "principal:controller",
        subject_principal_id: "principal:agent",
        conditions: %{audience: "jidoka:test", room_ids: ["room:one"]},
        provider_id: "provider:test",
        proof_type: "test-signature",
        proof_ref: "proof:test",
        expires_at: DateTime.add(now, 3_600, :second),
        metadata: %{signature: "must-not-persist"}
      })
    end
  end

  defp with_runtime(adapter, fun) do
    opts =
      if adapter == Persistence.SQLite,
        do: [persistence: adapter, persistence_opts: [path: tmp_path("identity-runtime")]],
        else: [persistence: adapter]

    start_supervised!({CredentialMessaging, opts})

    try do
      fun.(CredentialMessaging)
    after
      stop_supervised(CredentialMessaging)
    end
  end

  defp create_identity_scope(messaging) do
    {:ok, controller} =
      messaging.create_participant(%{
        id: "principal:controller",
        type: :human,
        identity: %{name: "Controller"}
      })

    {:ok, agent} =
      messaging.create_participant(%{
        id: "principal:agent",
        type: :agent,
        identity: %{name: "Jidoka Agent"}
      })

    {:ok, room} = messaging.create_room(%{id: "room:identity", type: :group, name: "Identity"})
    %{controller: controller, agent: agent, room: room}
  end

  defp credential_attrs(agent, controller, room, now \\ DateTime.utc_now()) do
    %{
      id: "credential:controller",
      issuer_principal_id: controller.id,
      subject_principal_id: agent.id,
      purpose: :controller,
      conditions: %{audience: "jidoka:test", room_ids: [room.id]},
      provider_id: "provider:test",
      proof_type: "test-signature-v1",
      proof_ref: "proof:controller-agent",
      key_version_ref: "key:v1",
      issued_at: now,
      not_before: now,
      expires_at: DateTime.add(now, 3_600, :second),
      metadata: %{source: "test"}
    }
  end

  defp proof(credential, assertion_id) do
    %{
      assertion_id: assertion_id,
      proof_type: credential.proof_type,
      proof_ref: credential.proof_ref,
      issued_at: DateTime.utc_now(),
      valid: true,
      raw_proof: "not-persisted"
    }
  end

  defp context(agent, controller, room) do
    %{
      subject_principal_id: agent.id,
      controller_principal_id: controller.id,
      audience: "jidoka:test",
      room_id: room.id
    }
  end

  defp tmp_path(prefix) do
    Path.join(System.tmp_dir!(), "jido-messaging-#{prefix}-#{System.unique_integer([:positive])}.sqlite3")
  end
end
