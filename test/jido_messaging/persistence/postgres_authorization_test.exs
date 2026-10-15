defmodule Jido.Messaging.Persistence.PostgresAuthorizationTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias Jido.Chat.Participant
  alias Jido.Messaging.{AuthorizationScope, Grant, InvocationPolicy, Membership, Persistence.Postgres, Runtime}
  alias Jido.Messaging.Signal.PostMessage
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.Postgres, runtime_profile: :core
  end

  setup do
    {:ok, state} = Factory.start_postgres()
    on_exit(fn -> Factory.stop_postgres(state) end)
    {:ok, state: state}
  end

  test "exports every principal and authorization callback required for production" do
    for {name, arity} <- [
          save_principal: 2,
          get_principal: 2,
          save_membership: 2,
          get_membership: 2,
          get_membership_by_scope: 3,
          list_memberships: 3,
          save_principal_grant: 2,
          get_principal_grant: 2,
          list_principal_grants: 3,
          save_invocation_policy: 2,
          get_invocation_policy: 2,
          get_invocation_policy_by_scope: 3,
          list_invocation_policies: 3
        ] do
      assert function_exported?(Postgres, name, arity), "missing required PostgreSQL function #{name}/#{arity}"
    end
  end

  test "typed posting persists once and checks revoked authority before cached results", %{state: state} do
    start_supervised!({Instance, persistence_opts: [pool: state.pool, instance_id: state.instance_id]})
    {:ok, room} = Instance.create_room(%{type: :group, name: "Postgres checkpoint"})
    {:ok, participant} = Instance.create_participant(%{type: :human})
    assert {:ok, principal} = Instance.get_principal(participant.id)
    assert principal.participant_id == participant.id

    {:ok, _membership} =
      Instance.create_membership(%{
        principal_id: principal.id,
        room_id: room.id,
        issuer_principal_id: "host"
      })

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

    {:ok, grant} =
      Instance.create_principal_grant(%{
        principal_id: principal.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope
      })

    request =
      PostMessage.new!(%{
        "request_id" => "postgres-post",
        "room_id" => room.id,
        "sender_id" => participant.id,
        "text" => "saved in PostgreSQL"
      })

    actor = [principal_id: principal.id, authorization_scope: scope]
    assert {:ok, result} = Instance.execute(request, actor)
    assert result.type == "jido.messaging.operation.completed"
    assert {:ok, message} = Postgres.get_message(state, result.data["result"]["id"])
    assert hd(message.content).text == "saved in PostgreSQL"
    assert {:ok, ^result} = Instance.execute(request, actor)
    assert {:ok, [^message]} = Instance.list_messages(room.id)
    assert {:ok, _} = Instance.revoke_principal_grant(grant.id, grant.revision)
    assert {:ok, denied} = Instance.execute(request, actor)
    assert denied.type == "jido.messaging.operation.failed"
    assert denied.data["code"] == "authorization_denied"
    assert {:ok, [^message]} = Instance.list_messages(room.id)
    assert {Postgres, _} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
  end

  test "membership alone does not grant authority and invocation needs a current policy", %{state: state} do
    start_supervised!({Instance, persistence_opts: [pool: state.pool, instance_id: state.instance_id]})
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, person} = Instance.create_participant(%{type: :human})
    {:ok, agent} = Instance.create_participant(%{type: :agent})

    {:ok, membership} =
      Instance.create_membership(%{
        principal_id: person.id,
        room_id: room.id,
        issuer_principal_id: "host"
      })

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id, target_principal_id: agent.id})

    assert {:error, {:authorization_denied, :no_matching_grant, _}} =
             Instance.authorize(person.id, :invoke_agent, scope)

    {:ok, _grant} =
      Instance.create_principal_grant(%{
        principal_id: person.id,
        issuer_principal_id: "host",
        actions: [:invoke_agent],
        scope: scope
      })

    assert {:error, {:authorization_denied, :invocation_policy_required, _}} =
             Instance.authorize(person.id, :invoke_agent, scope)

    {:ok, policy} =
      Instance.create_invocation_policy(%{
        target_principal_id: agent.id,
        issuer_principal_id: "host",
        mode: :room_members,
        scope: scope
      })

    assert {:ok, decision} = Instance.authorize(person.id, :invoke_agent, scope)
    assert decision.invocation_policy_id == policy.id
    assert {:ok, _} = Instance.transition_membership(membership.id, membership.revision, :revoked)

    assert {:error, {:authorization_denied, :membership_required, _}} =
             Instance.authorize(person.id, :invoke_agent, scope)
  end

  for kind <- [:membership, :grant, :policy] do
    test "#{kind} revision races across pools accept only one changed revision", %{state: state} do
      kind = unquote(kind)

      {:ok, second} =
        Postgres.init(url: System.fetch_env!("JIDO_MESSAGING_POSTGRES_URL"), instance_id: state.instance_id)

      Process.unlink(second.pool)
      on_exit(fn -> Postgres.close(second) end)
      record = record(kind)
      assert {:ok, ^record} = save(state, kind, record)

      results =
        concurrent([state, second], fn connection, index ->
          save(connection, kind, %{record | revision: 2, metadata: %{writer: index}})
        end)

      assert length(Enum.filter(results, &match?({:ok, _}, &1))) == 1
      assert length(Enum.filter(results, &(&1 == {:error, {:stale_revision, 2}}))) == 7
    end
  end

  for {kind, reason} <- [membership: :membership_scope_conflict, policy: :invocation_policy_scope_conflict] do
    test "#{kind} scope races keep one owner", %{state: state} do
      kind = unquote(kind)
      record = record(kind)

      results =
        concurrent([state], fn connection, index ->
          save(connection, kind, %{record | id: "candidate-#{index}"})
        end)

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert length(Enum.filter(results, &(&1 == {:error, {unquote(reason), winner.id}}))) == 7
    end
  end

  test "authorization cleanup and lookups retain another namespace", %{state: state} do
    {:ok, other} = Factory.start_postgres()
    on_exit(fn -> Factory.stop_postgres(other) end)
    person = Participant.new(%{id: "owned", type: :human})
    records = Enum.map([:membership, :grant, :policy], &{&1, record(&1)})

    for connection <- [state, other] do
      assert {:ok, ^person} = Postgres.save_participant(connection, person)
      for {kind, record} <- records, do: assert({:ok, record} == save(connection, kind, record))
    end

    assert :ok = Postgres.delete_participant(state, person.id)
    assert {:error, :not_found} = Postgres.get_principal(state, person.id)

    for {kind, record} <- records do
      assert {:error, :not_found} = get(state, kind, record.id)
      assert {:ok, ^record} = get(other, kind, record.id)
    end

    assert {:ok, _principal} = Postgres.get_principal(other, person.id)
    assert :ok = Postgres.delete_room(other, "room")
    for {kind, record} <- records, do: assert({:error, :not_found} == get(other, kind, record.id))
    assert {:ok, ^person} = Postgres.get_participant(other, person.id)
  end

  test "old participant payloads acquire a principal without changing the participant", %{state: state} do
    person = Participant.new(%{id: "legacy-person", type: :human})

    assert {:ok, _} =
             Postgrex.query(
               state.conn,
               "INSERT INTO jido_messaging_records (instance_id, kind, id, payload) VALUES ($1, 'participant', $2, $3)",
               [state.instance_id, person.id, :erlang.term_to_binary(person)]
             )

    assert {:ok, principal} = Postgres.get_principal(state, person.id)
    assert principal.id == person.id
    assert {:ok, ^person} = Postgres.get_participant(state, person.id)
    assert {:ok, ^principal} = Postgres.get_principal(state, person.id)
  end

  test "grant action filters and list limits preserve deterministic order", %{state: state} do
    base = record(:grant)
    first = %{base | id: "first", inserted_at: ~U[2026-01-01 00:00:00Z]}
    second = %{base | id: "second", actions: [:read_transcript], inserted_at: ~U[2026-01-01 00:00:01Z]}
    third = %{base | id: "third", status: :suspended, inserted_at: ~U[2026-01-01 00:00:02Z]}
    for record <- [third, second, first], do: assert({:ok, record} == Postgres.save_principal_grant(state, record))
    assert {:ok, [^first, ^second, ^third]} = Postgres.list_principal_grants(state, "owned", limit: :invalid)
    assert {:ok, [^first, ^third]} = Postgres.list_principal_grants(state, "owned", action: :post_message)

    assert {:ok, [^first]} =
             Postgres.list_principal_grants(state, "owned", status: :active, action: :post_message, limit: 1)

    assert {:ok, []} = Postgres.list_principal_grants(state, "other")
  end

  test "a transaction rollback removes authorization writes", %{state: state} do
    membership = record(:membership)

    assert {:error, :cancelled} =
             Postgres.transaction(state, fn transaction_state ->
               assert {:ok, ^membership} = Postgres.save_membership(transaction_state, membership)
               {:error, :cancelled}
             end)

    assert {:error, :not_found} = Postgres.get_membership(state, membership.id)
    assert {:error, :not_found} = Postgres.get_membership_by_scope(state, membership.room_id, membership.principal_id)
  end

  defp concurrent(states, fun) do
    1..8
    |> Task.async_stream(fn index -> fun.(Enum.at(states, rem(index, length(states))), index) end,
      max_concurrency: 8,
      timeout: 30_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp record(:membership),
    do:
      Membership.new(%{
        id: "membership",
        principal_id: "owned",
        room_id: "room",
        issuer_principal_id: "host"
      })

  defp record(:grant),
    do:
      Grant.new(%{
        id: "grant",
        principal_id: "owned",
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: %{kind: :room, room_id: "room"}
      })

  defp record(:policy),
    do:
      InvocationPolicy.new(%{
        id: "policy",
        target_principal_id: "owned",
        issuer_principal_id: "host",
        mode: :nobody,
        scope: %{kind: :room, room_id: "room"}
      })

  defp save(state, :membership, record), do: Postgres.save_membership(state, record)
  defp save(state, :grant, record), do: Postgres.save_principal_grant(state, record)
  defp save(state, :policy, record), do: Postgres.save_invocation_policy(state, record)
  defp get(state, :membership, id), do: Postgres.get_membership(state, id)
  defp get(state, :grant, id), do: Postgres.get_principal_grant(state, id)
  defp get(state, :policy, id), do: Postgres.get_invocation_policy(state, id)
end
