defmodule Jido.Messaging.FacadeRecordOwnershipTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging
  alias Jido.Messaging.{AuthorizationScope}

  defmodule ETSInstance do
    use Messaging, persistence: Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule SQLiteInstance do
    use Messaging, persistence: Messaging.Persistence.SQLite, runtime_profile: :core
  end

  defmodule Projection do
    @behaviour Messaging.SearchProjection
    def upsert(entry, context, _opts) do
      send(self(), {:upsert, entry, context})
      :ok
    end

    def delete(id, context, _opts) do
      send(self(), {:delete, id, context})
      :ok
    end

    def search(query, context, _opts) do
      send(self(), {:search, query, context})
      {:ok, Process.get(:projection_results, [])}
    end

    def rebuild(entries, context, _opts) do
      send(self(), {:rebuild, entries, context})
      :ok
    end
  end

  setup do
    path = Path.join(System.tmp_dir!(), "facade-ownership-#{System.unique_integer([:positive])}.sqlite3")
    start_supervised!(ETSInstance)
    start_supervised!({SQLiteInstance, persistence_opts: [path: path]})
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp runtime(instance), do: instance.__jido_messaging__(:runtime)

  defp seed(instance) do
    owner = runtime(instance)
    {:ok, room} = Messaging.create_room(owner, %{id: "same-room", type: :group, name: "Owned"})
    {:ok, human} = Messaging.create_participant(owner, %{id: "same-human", type: :human})
    {:ok, agent} = Messaging.create_participant(owner, %{id: "same-agent", type: :agent})

    {:ok, thread} =
      Messaging.save_thread(owner, %{
        id: "same-thread",
        room_id: room.id,
        external_thread_id: "external-thread",
        root_message_id: "root"
      })

    {owner, room, human, agent, thread}
  end

  defp no_communication(instance) do
    assert Jido.Messaging.TestHelpers.runtime_entry_count(runtime(instance)) == 0
    assert instance.count_agents() == 0
    refute_received {:signal, _}
  end

  defp projection(instance) do
    previous = Application.fetch_env(instance, :search_projection)
    Application.put_env(instance, :search_projection, Projection)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(instance, :search_projection, value)
        :error -> Application.delete_env(instance, :search_projection)
      end
    end)
  end

  test "history and projection facade defaults retain canonical data and mandatory room scope" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, room, human, _, _} = seed(instance)
      projection(instance)
      assert {:ok, scope} = Messaging.HistoryScope.new(instance, [room.id])

      assert {:ok, message} =
               Messaging.save_message(owner, %{
                 room_id: room.id,
                 sender_id: human.id,
                 role: :user,
                 content: [%{type: :text, text: "owned"}]
               })

      assert {:ok, [entry]} = Messaging.participant_transcript(instance, owner, human.id, scope)
      assert entry.message == message
      assert :ok = Messaging.upsert_transcript_search(instance, owner, message.id, scope)
      assert_received {:upsert, ^entry, %{scope: ^scope}}
      Process.put(:projection_results, [entry])
      assert {:ok, [^entry]} = Messaging.search_transcript(instance, "owned", scope)
      assert_received {:search, "owned", %{scope: ^scope}}
      assert :ok = Messaging.rebuild_transcript_search(instance, owner, human.id, scope)
      assert_received {:rebuild, [^entry], %{scope: ^scope}}
      assert :ok = Messaging.delete_transcript_search(instance, message.id, room.id, scope)
      assert_received {:delete, _, %{scope: ^scope}}

      assert {:error, :history_scope_violation} =
               Messaging.delete_transcript_search(instance, message.id, "foreign-room", scope)

      refute_received {:delete, _, _}

      assert {:error, :history_scope_instance_mismatch} =
               Messaging.participant_transcript(instance, owner, human.id, %{scope | instance_module: OtherInstance})

      assert {:error, :history_scope_required} = Messaging.search_transcript(instance, "owned", %{})
      Process.put(:projection_results, :invalid)
      assert {:error, :invalid_search_projection_result} = Messaging.search_transcript(instance, "owned", scope)
      no_communication(instance)
    end
  end

  test "a projection cannot replace canonical principal identity or assurance" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, room, human, _, _} = seed(instance)
      projection(instance)
      assert {:ok, scope} = Messaging.HistoryScope.new(instance, [room.id])

      assert {:ok, _} =
               Messaging.save_message(owner, %{
                 room_id: room.id,
                 sender_id: human.id,
                 role: :user,
                 content: [%{type: :text, text: "owned"}]
               })

      assert {:ok, [entry]} = Messaging.participant_transcript(instance, owner, human.id, scope)

      for tampered <- [
            %{entry | principal_id: "foreign-principal"},
            %{entry | authorship_assurance: :provider_verified},
            %{entry | authorship: %{entry.authorship | principal_id: "foreign-principal"}},
            %{entry | message: %{entry.message | content: [%{type: :text, text: "fabricated"}]}}
          ] do
        Process.put(:projection_results, [tampered])
        assert {:error, :search_projection_scope_violation} = Messaging.search_transcript(instance, "owned", scope)
      end

      assert {:ok, [^entry]} = Messaging.participant_transcript(instance, owner, human.id, scope)
      no_communication(instance)
    end
  end

  test "canonical projection checks retain timestamp-less history but reject a deleted record" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, room, human, _, _} = seed(instance)
      projection(instance)
      assert {:ok, scope} = Messaging.HistoryScope.new(instance, [room.id])

      record =
        Messaging.Message.new(%{
          room_id: room.id,
          sender_id: human.id,
          role: :user,
          content: [%{type: :text, text: "legacy"}],
          inserted_at: nil,
          updated_at: nil
        })

      assert {:ok, _} = Messaging.save_message_struct(owner, record)
      assert {:ok, [entry]} = Messaging.participant_transcript(instance, owner, human.id, scope)
      Process.put(:projection_results, [entry])
      assert {:ok, [^entry]} = Messaging.search_transcript(instance, "legacy", scope)
      assert :ok = Messaging.delete_message(owner, record.id)
      assert {:error, :search_projection_scope_violation} = Messaging.search_transcript(instance, "legacy", scope)
      assert {:ok, []} = Messaging.participant_transcript(instance, owner, human.id, scope)
      no_communication(instance)
    end
  end

  test "low-level facade record operations preserve instance isolation and emit no communication" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {:ok, _} = instance.subscribe_signals("jido.messaging.**")
      {owner, room, human, _, thread} = seed(instance)
      assert {:ok, ^room} = Messaging.get_room(owner, room.id)
      assert {:ok, [^room]} = Messaging.list_rooms(owner)
      assert {:ok, ^human} = Messaging.get_participant(owner, human.id)
      assert {:ok, ^thread} = Messaging.get_thread_by_root_message(owner, room.id, "root")
      assert {:ok, [^thread]} = Messaging.list_threads(owner, room.id)

      assert {:ok, message} =
               Messaging.save_message(owner, %{
                 id: "same-message",
                 room_id: room.id,
                 sender_id: human.id,
                 role: :user,
                 content: [%{type: :text, text: Atom.to_string(instance)}]
               })

      assert {:ok, [^message]} = Messaging.list_messages(owner, room.id)
      no_communication(instance)
    end

    assert {:ok, first} = Messaging.get_message(runtime(ETSInstance), "same-message")
    assert {:ok, second} = Messaging.get_message(runtime(SQLiteInstance), "same-message")
    assert first.content != second.content
    assert :ok = Messaging.delete_room(runtime(ETSInstance), "same-room")
    assert {:error, :not_found} = Messaging.get_message(runtime(ETSInstance), "same-message")
    assert {:ok, ^second} = Messaging.get_message(runtime(SQLiteInstance), "same-message")
  end

  test "membership and grant facade defaults retain revision and terminal revocation checks" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, room, human, _, _} = seed(instance)
      scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

      assert {:ok, member} =
               Messaging.create_membership(owner, %{
                 principal_id: human.id,
                 room_id: room.id,
                 issuer_principal_id: human.id
               })

      assert {:ok, [^member]} = Messaging.list_memberships(owner, room.id)
      assert {:ok, ^member} = Messaging.get_membership(owner, member.id)
      assert {:ok, suspended} = Messaging.transition_membership(owner, member.id, 1, :suspended)
      assert {:error, {:stale_revision, 2}} = Messaging.transition_membership(owner, member.id, 1, :active)
      assert {:ok, revoked} = Messaging.transition_membership(owner, member.id, suspended.revision, :revoked)

      assert {:error, :authorization_revocation_terminal} =
               Messaging.transition_membership(owner, member.id, revoked.revision, :active)

      assert {:ok, grant} =
               Messaging.create_principal_grant(owner, %{
                 principal_id: human.id,
                 issuer_principal_id: human.id,
                 actions: [:post_message],
                 scope: scope
               })

      assert {:ok, [^grant]} = Messaging.list_principal_grants(owner, human.id)
      assert {:ok, ^grant} = Messaging.get_principal_grant(owner, grant.id)
      assert {:ok, changed} = Messaging.revise_principal_grant(owner, grant.id, 1, %{actions: [:read_transcript]})
      assert {:ok, revoked_grant} = Messaging.revoke_principal_grant(owner, grant.id, changed.revision)

      assert {:error, :authorization_revocation_terminal} =
               Messaging.revise_principal_grant(owner, grant.id, revoked_grant.revision, %{status: :active})

      no_communication(instance)
    end
  end

  test "invocation policy facade defaults retain the canonical target and immutable scope" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, room, human, agent, _} = seed(instance)
      scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

      assert {:ok, policy} =
               Messaging.create_invocation_policy(owner, %{
                 target_principal_id: agent.id,
                 issuer_principal_id: human.id,
                 mode: :nobody,
                 scope: scope
               })

      assert {:ok, ^policy} = Messaging.get_invocation_policy(owner, policy.id)
      assert {:ok, [^policy]} = Messaging.list_invocation_policies(owner, agent.id)
      assert {:ok, changed} = Messaging.revise_invocation_policy(owner, policy.id, 1, %{mode: :anyone})
      assert changed.target_principal_id == agent.id
      assert {:ok, revoked} = Messaging.revoke_invocation_policy(owner, policy.id, changed.revision)

      assert {:error, :authorization_revocation_terminal} =
               Messaging.revise_invocation_policy(owner, policy.id, revoked.revision, %{status: :active})

      no_communication(instance)
    end
  end

  test "provider identity facade retains canonical ownership across revocation" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, _, human, _, _} = seed(instance)
      assert {:ok, principal} = Messaging.principal_for_participant(owner, human.id)
      assert {:ok, same} = Messaging.get_principal(owner, principal.id)
      assert same.participant_id == human.id
      assert {:ok, binding} = Messaging.bind_external_identity(owner, principal.id, :telegram, "bridge", "peer")
      assert {:ok, [^binding]} = Messaging.list_external_identity_bindings(owner, principal.id)
      assert {:ok, ^binding} = Messaging.get_external_identity_binding(owner, binding.id)
      assert {:ok, revoked} = Messaging.revoke_external_identity_binding(owner, binding.id)
      assert revoked.status == :revoked

      assert {:error, :external_identity_revoked} =
               Messaging.bind_external_identity(owner, principal.id, :telegram, "bridge", "peer")

      assert {:ok, ^human} = Messaging.get_participant(owner, human.id)
      no_communication(instance)
    end
  end

  test "endpoint facade record operations do not start agents or infer grants" do
    for instance <- [ETSInstance, SQLiteInstance] do
      {owner, room, _, agent, thread} = seed(instance)

      assert {:ok, endpoint} =
               Messaging.create_agent_messaging_endpoint(owner, %{
                 principal_id: agent.id,
                 jidoka_agent_ref: %{system: :jidoka, id: "jidoka-agent"}
               })

      assert {:ok, ^endpoint} = Messaging.get_agent_messaging_endpoint_by_ref(owner, "jidoka-agent")
      assert {:ok, [^endpoint]} = Messaging.list_agent_messaging_endpoints(owner)
      assert {:ok, available} = Messaging.set_agent_endpoint_availability(owner, endpoint.id, :available)
      assert {:ok, member} = Messaging.add_agent_endpoint_to_room(owner, endpoint.id, room.id)
      assert {:ok, ^member} = Messaging.get_agent_room_membership(owner, member.id)
      assert {:ok, [^member]} = Messaging.list_agent_room_memberships(owner, room.id)
      assert {:ok, route} = Messaging.route_thread_to_agent_endpoint(owner, thread.id, endpoint.id)
      assert {:ok, [^route]} = Messaging.list_agent_thread_routes(owner, endpoint.id)

      assert {:ok, updated} =
               Messaging.put_agent_thread_route_correlations(owner, thread.id, %{jidoka_request_ref: "opaque-request"})

      assert updated.endpoint_id == endpoint.id
      assert {:ok, target} = Messaging.resolve_agent_thread_endpoint(owner, thread.id)
      assert target.endpoint.id == available.id
      assert {:ok, []} = Messaging.list_principal_grants(owner, agent.id)
      assert {:ok, []} = Messaging.list_memberships(owner, room.id)
      assert {:ok, revoked_route} = Messaging.revoke_agent_thread_route(owner, thread.id)
      assert revoked_route.status == :revoked
      assert {:ok, revoked_member} = Messaging.revoke_agent_room_membership(owner, member.id)
      assert revoked_member.status == :revoked
      assert {:ok, revoked_endpoint} = Messaging.revoke_agent_messaging_endpoint(owner, endpoint.id)
      assert revoked_endpoint.status == :revoked
      no_communication(instance)
    end
  end
end
