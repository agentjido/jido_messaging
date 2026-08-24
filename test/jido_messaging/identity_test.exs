defmodule Jido.Messaging.IdentityTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{Authorship, Ingest, Principal, Runtime, TranscriptEntry}

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule MockChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :mock

    @impl true
    def transform_incoming(_payload), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "mock-message"}}
  end

  defmodule VerifiedSecurity do
    @behaviour Jido.Messaging.Security

    @impl true
    def verify_sender(_channel_module, _incoming_message, _raw_payload, _opts) do
      {:ok,
       %{
         identity_assurance: :provider_verified,
         identity_proof_ref: "provider-request:req-123"
       }}
    end

    @impl true
    def sanitize_outbound(_channel_module, outbound, _opts), do: {:ok, outbound}
  end

  defmodule NoIdentityPersistence do
  end

  setup do
    path = Path.join(System.tmp_dir!(), "jido-messaging-identity-#{System.unique_integer([:positive])}.sqlite3")
    File.rm(path)

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "principals keep typed lifecycle, controller, and opaque Jidoka reference data" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      controller = create_participant(messaging, "#{prefix}-controller", :human)
      agent = create_participant(messaging, "#{prefix}-agent", :agent)

      assert {:ok, controller_principal} = messaging.principal_for_participant(controller.id)
      assert {:ok, agent_principal} = messaging.principal_for_participant(agent.id)
      assert controller_principal.id == controller.id
      assert agent_principal.id == agent.id
      assert agent_principal.verification_state == :unverified

      updated = %{
        agent_principal
        | controller_principal_id: controller_principal.id,
          credential_state: :active,
          agent_ref: %{"system" => "jidoka", "id" => "support-agent"},
          updated_at: DateTime.utc_now()
      }

      assert {:ok, ^updated} = messaging.save_principal(updated)
      assert {:ok, ^updated} = messaging.get_principal(agent.id)

      self_controlled = %{updated | controller_principal_id: updated.id}
      assert {:error, :principal_cannot_control_itself} = messaging.save_principal(self_controlled)

      assert {:error, :invalid_identity_assurance} =
               messaging.bind_external_identity(
                 updated.id,
                 :mock,
                 "invalid-assurance-bridge",
                 "invalid-assurance-provider",
                 assurance: :provider_verifed
               )

      revoked = %{updated | verification_state: :revoked, updated_at: DateTime.utc_now()}
      assert {:ok, ^revoked} = messaging.save_principal(revoked)

      assert {:error, :principal_verification_revoked} =
               messaging.bind_external_identity(
                 revoked.id,
                 :mock,
                 "revoked-principal-bridge",
                 "revoked-principal-provider"
               )
    end
  end

  test "principal agent references cannot contain executable agent definitions" do
    assert_raise ArgumentError, ~r/agent_ref permits only/, fn ->
      Principal.new(%{
        participant_id: "unsafe-agent-ref",
        type: :agent,
        agent_ref: %{
          system: "jidoka",
          id: "support-agent",
          module: __MODULE__
        }
      })
    end
  end

  test "participant deletion removes its principal and scoped bindings" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      participant = create_participant(messaging, "#{prefix}-delete-identity", :human)
      {:ok, principal} = messaging.principal_for_participant(participant.id)

      {:ok, binding} =
        messaging.bind_external_identity(
          principal.id,
          :mock,
          "delete-bridge",
          "delete-provider-user"
        )

      {persistence, state} = Runtime.get_persistence(messaging.__jido_messaging__(:runtime))
      assert :ok = persistence.delete_participant(state, participant.id)
      assert {:error, :not_found} = persistence.get_principal(state, principal.id)
      assert {:error, :not_found} = persistence.get_external_identity_binding(state, binding.id)
    end
  end

  test "binding record IDs are opaque across messaging instances" do
    participant_id = "opaque-binding-principal"
    ets_participant = create_participant(ETSMessaging, participant_id, :human)
    sqlite_participant = create_participant(SQLiteMessaging, participant_id, :human)

    {:ok, ets_principal} = ETSMessaging.principal_for_participant(ets_participant.id)
    {:ok, sqlite_principal} = SQLiteMessaging.principal_for_participant(sqlite_participant.id)

    {:ok, ets_binding} =
      ETSMessaging.bind_external_identity(
        ets_principal.id,
        :mock,
        "opaque-workspace",
        "private-provider-id"
      )

    {:ok, sqlite_binding} =
      SQLiteMessaging.bind_external_identity(
        sqlite_principal.id,
        :mock,
        "opaque-workspace",
        "private-provider-id"
      )

    refute ets_binding.id == sqlite_binding.id
    refute ets_binding.id =~ "opaque-workspace"
    refute ets_binding.id =~ "private-provider-id"
  end

  test "adapters without identity callbacks keep authorship but do not claim a durable binding" do
    participant = Jido.Chat.Participant.new(%{id: "compat-participant", type: :human})
    principal = Principal.from_participant(participant)

    verify_result = %{
      metadata: %{
        identity_assurance: :provider_verified,
        identity_proof_ref: "compat-proof"
      }
    }

    assert {:ok, resolved_principal, _binding, authorship} =
             Jido.Messaging.Identity.resolve_authorship(
               NoIdentityPersistence,
               nil,
               participant,
               :mock,
               "compat-bridge",
               "compat-user",
               verify_result
             )

    assert resolved_principal.id == principal.id
    assert resolved_principal.verification_state == :verified
    assert authorship.assurance == :provider_verified
    assert authorship.external_identity_binding_id == nil

    assert {:error, :unsupported} =
             Jido.Messaging.Identity.bind_external_identity(
               NoIdentityPersistence,
               nil,
               principal,
               :mock,
               "compat-bridge",
               "compat-user"
             )
  end

  test "bridge-scoped bindings keep provider identity correct in transcripts" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      participant = create_participant(messaging, "#{prefix}-linked", :human, %{mock: "legacy-wrong-id"})
      {:ok, principal} = messaging.principal_for_participant(participant.id)

      assert {:ok, binding_a} =
               messaging.bind_external_identity(
                 principal.id,
                 :mock,
                 "workspace-a",
                 "provider-user-a",
                 assurance: :application_verified,
                 proof_ref: "account-link:1"
               )

      assert {:ok, binding_b} =
               messaging.bind_external_identity(
                 principal.id,
                 :mock,
                 "workspace-b",
                 "provider-user-b"
               )

      assert {:ok, %Principal{verification_state: :verified}} =
               messaging.get_principal(principal.id)

      {:ok, room} = messaging.create_room(%{id: "#{prefix}-identity-room", type: :group})

      message_a = save_message(messaging, room.id, participant.id, "#{prefix}-message-a", "workspace-a")
      message_b = save_message(messaging, room.id, participant.id, "#{prefix}-message-b", "workspace-b")

      {:ok, scope} = messaging.history_scope([room.id])
      assert {:ok, [entry_a, entry_b]} = messaging.participant_transcript(participant.id, scope, limit: 10)

      assert %TranscriptEntry{} = entry_a
      assert entry_a.canonical_message_id == message_a.id
      assert entry_a.provider_participant_id == "provider-user-a"
      assert entry_a.external_identity_binding_id == binding_a.id
      assert entry_a.authorship_assurance == :asserted

      assert entry_b.canonical_message_id == message_b.id
      assert entry_b.provider_participant_id == "provider-user-b"
      assert entry_b.external_identity_binding_id == binding_b.id
      refute entry_a.external_identity_binding_id == entry_b.external_identity_binding_id
    end
  end

  test "equal provider IDs in different bridges create separate principals" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)

      assert {:ok, first} =
               messaging.get_or_create_participant_by_external_id(
                 :mock,
                 "tenant-a",
                 "shared-provider-user",
                 %{type: :human, identity: %{display_name: "Same Name"}, id: "#{prefix}-tenant-a"}
               )

      assert {:ok, second} =
               messaging.get_or_create_participant_by_external_id(
                 :mock,
                 "tenant-b",
                 "shared-provider-user",
                 %{type: :human, identity: %{display_name: "Same Name"}, id: "#{prefix}-tenant-b"}
               )

      refute first.id == second.id
      assert {:ok, first_principal} = messaging.principal_for_participant(first.id)
      assert {:ok, second_principal} = messaging.principal_for_participant(second.id)
      refute first_principal.id == second_principal.id

      assert {:ok, ^first} =
               messaging.directory_lookup(:participant, %{
                 channel: :mock,
                 bridge_id: "tenant-a",
                 external_id: "shared-provider-user"
               })

      assert {:ok, ^second} =
               messaging.directory_lookup(:participant, %{
                 channel: :mock,
                 bridge_id: "tenant-b",
                 external_id: "shared-provider-user"
               })

      assert {:error, {:ambiguous, matches}} =
               messaging.directory_lookup(:participant, %{
                 channel: :mock,
                 external_id: "shared-provider-user"
               })

      assert Enum.map(matches, & &1.id) == Enum.sort([first.id, second.id])
    end
  end

  test "legacy transcript projection does not guess between two identities in one bridge" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)

      participant =
        create_participant(
          messaging,
          "#{prefix}-ambiguous",
          :human,
          %{mock: "legacy-ambiguous-id"}
        )

      {:ok, principal} = messaging.principal_for_participant(participant.id)

      {:ok, _first} =
        messaging.bind_external_identity(
          principal.id,
          :mock,
          "shared-workspace",
          "provider-account-one"
        )

      {:ok, _second} =
        messaging.bind_external_identity(
          principal.id,
          :mock,
          "shared-workspace",
          "provider-account-two"
        )

      {:ok, room} = messaging.create_room(%{id: "#{prefix}-ambiguous-room", type: :group})
      _message = save_message(messaging, room.id, participant.id, "#{prefix}-ambiguous-message", "shared-workspace")

      {:ok, scope} = messaging.history_scope([room.id])
      assert {:ok, [entry]} = messaging.participant_transcript(participant.id, scope)
      assert entry.provider_participant_id == nil
      assert entry.external_identity_binding_id == nil
    end
  end

  test "transcript projection rejects authorship metadata for another principal" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      participant = create_participant(messaging, "#{prefix}-forged-authorship", :human)
      {:ok, room} = messaging.create_room(%{id: "#{prefix}-forged-authorship-room", type: :group})

      forged =
        Authorship.new(%{
          principal_id: "another-principal",
          participant_id: participant.id,
          assurance: :cryptographically_verified
        })

      {:ok, _message} =
        messaging.save_message(%{
          id: "#{prefix}-forged-authorship-message",
          room_id: room.id,
          sender_id: participant.id,
          role: :user,
          content: [%{type: :text, text: "Forged claim"}],
          inserted_at: DateTime.utc_now(),
          metadata: %{authorship: Authorship.to_map(forged)}
        })

      {:ok, scope} = messaging.history_scope([room.id])
      assert {:ok, [entry]} = messaging.participant_transcript(participant.id, scope)
      assert entry.principal_id == participant.id
      assert entry.authorship_assurance == :asserted
    end
  end

  test "ingest stores verified authorship without storing raw proof data" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)

      incoming = %{
        external_room_id: "#{prefix}-verified-room",
        external_user_id: "#{prefix}-verified-user",
        external_message_id: "#{prefix}-verified-message",
        username: "verified-user",
        text: "Verified message"
      }

      assert {:ok, message, context} =
               Ingest.ingest_incoming(
                 messaging,
                 MockChannel,
                 "verified-bridge",
                 incoming,
                 security: [adapter: VerifiedSecurity]
               )

      assert {:ok, authorship} = Authorship.from_map(message.metadata.authorship)
      assert authorship.principal_id == context.participant.id
      assert authorship.assurance == :provider_verified
      assert authorship.proof_ref == "provider-request:req-123"
      assert is_binary(authorship.external_identity_binding_id)

      assert {:ok, binding} =
               messaging.get_external_identity_binding(authorship.external_identity_binding_id)

      assert binding.channel == "mock"
      assert binding.bridge_id == "verified-bridge"
      assert binding.external_id == incoming.external_user_id
      assert binding.assurance == :provider_verified

      assert {:ok, %Principal{verification_state: :verified}} =
               messaging.get_principal(authorship.principal_id)

      {:ok, scope} = messaging.history_scope([context.room.id])
      assert {:ok, [entry]} = messaging.participant_transcript(context.participant.id, scope)
      assert entry.authorship == authorship
      assert entry.provider_participant_id == incoming.external_user_id
    end
  end

  test "revoked bindings remain auditable and cannot accept new messages" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      participant = create_participant(messaging, "#{prefix}-revoked", :human)
      {:ok, principal} = messaging.principal_for_participant(participant.id)

      assert {:ok, binding} =
               messaging.bind_external_identity(
                 principal.id,
                 :mock,
                 "revoked-bridge",
                 "revoked-provider-user"
               )

      assert {:ok, revoked} = messaging.revoke_external_identity_binding(binding.id)
      assert revoked.status == :revoked
      assert %DateTime{} = revoked.revoked_at
      assert {:ok, ^revoked} = messaging.get_external_identity_binding(binding.id)

      assert {:error, :external_identity_revoked} =
               messaging.get_or_create_participant_by_external_id(
                 :mock,
                 "revoked-bridge",
                 "revoked-provider-user",
                 %{type: :human}
               )

      assert {:error, :external_identity_revoked} =
               messaging.bind_external_identity(
                 principal.id,
                 :mock,
                 "revoked-bridge",
                 "revoked-provider-user"
               )
    end
  end

  defp create_participant(messaging, id, type, external_ids \\ %{}) do
    {:ok, participant} =
      messaging.create_participant(%{
        id: id,
        type: type,
        identity: %{display_name: id},
        external_ids: external_ids
      })

    participant
  end

  defp save_message(messaging, room_id, participant_id, id, bridge_id) do
    {:ok, message} =
      messaging.save_message(%{
        id: id,
        room_id: room_id,
        sender_id: participant_id,
        role: :user,
        content: [%{type: :text, text: id}],
        external_id: "provider-#{id}",
        inserted_at: DateTime.utc_now(),
        metadata: %{channel: :mock, bridge_id: bridge_id}
      })

    message
  end

  defp prefix(messaging), do: messaging |> Module.split() |> List.last() |> String.downcase()
end
