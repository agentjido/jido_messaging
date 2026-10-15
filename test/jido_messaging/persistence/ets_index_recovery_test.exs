defmodule Jido.Messaging.Persistence.ETSIndexRecoveryTest do
  use ExUnit.Case, async: true
  alias Jido.Messaging.{AuthorizationScope, ExternalIdentityBinding, InvocationPolicy, Membership, Message}
  alias Jido.Messaging.Persistence.ETS

  setup do
    {:ok, state} = ETS.init([])
    {:ok, state: state}
  end

  test "missing room recovery removes only its stale binding indexes and keeps history", %{state: state} do
    assert {:ok, owned} =
             ETS.get_or_create_room_by_external_binding(state, :slack, "owned", "shared", %{
               id: "old-room",
               type: :group
             })

    assert {:ok, foreign} =
             ETS.get_or_create_room_by_external_binding(state, :slack, "foreign", "shared", %{
               id: "foreign-room",
               type: :group,
               metadata: %{complete: "foreign"}
             })

    assert {:ok, [old_binding]} = ETS.list_room_bindings(state, owned.id)
    assert {:ok, [foreign_binding]} = ETS.list_room_bindings(state, foreign.id)

    message =
      Message.new(%{
        id: "old-history",
        room_id: owned.id,
        sender_id: "sender",
        role: :user,
        content: [%{type: :text, text: "Complete old history"}],
        metadata: %{complete: "retained"}
      })

    assert {:ok, ^message} = ETS.save_message(state, message)
    :ets.delete(state.rooms, owned.id)

    assert {:ok, recovered} =
             ETS.get_or_create_room_by_external_binding(state, :slack, "owned", "shared", %{
               id: "recovered-room",
               type: :group,
               metadata: %{complete: "recovered"}
             })

    assert recovered.id == "recovered-room"
    assert {:ok, ^recovered} = ETS.get_room_by_external_binding(state, :slack, "owned", "shared")
    assert {:ok, [new_binding]} = ETS.list_room_bindings(state, recovered.id)
    assert new_binding.room_id == recovered.id
    assert new_binding.id != old_binding.id
    assert {:ok, []} = ETS.list_room_bindings(state, owned.id)
    assert :ets.lookup(state.room_bindings_by_id, old_binding.id) == []
    assert :ets.lookup(state.room_bindings_by_room, owned.id) == []
    assert {:ok, ^message} = ETS.get_message(state, message.id)
    assert {:ok, ^foreign} = ETS.get_room_by_external_binding(state, :slack, "foreign", "shared")
    assert {:ok, [^foreign_binding]} = ETS.list_room_bindings(state, foreign.id)
    assert {:ok, ^recovered} = ETS.get_or_create_room_by_external_binding(state, :slack, "owned", "shared", %{})
    assert {:ok, [^new_binding]} = ETS.list_room_bindings(state, recovered.id)
  end

  test "missing participant recovery replaces only its active bridge identity", %{state: state} do
    {:ok, owned} =
      ETS.get_or_create_participant_by_external_binding(state, :slack, "owned", "shared", %{
        id: "old-person",
        type: :human
      })

    {:ok, foreign} =
      ETS.get_or_create_participant_by_external_binding(state, :slack, "foreign", "shared", %{
        id: "foreign-person",
        type: :human,
        metadata: %{complete: "foreign"}
      })

    {:ok, old_binding} = ETS.get_external_identity_binding(state, :slack, "owned", "shared")
    {:ok, foreign_binding} = ETS.get_external_identity_binding(state, :slack, "foreign", "shared")
    :ets.delete(state.participants, owned.id)

    assert {:ok, recovered} =
             ETS.get_or_create_participant_by_external_binding(state, :slack, "owned", "shared", %{
               id: "new-person",
               type: :human,
               metadata: %{complete: "recovered"}
             })

    assert recovered.id == "new-person"
    assert {:ok, replacement} = ETS.get_external_identity_binding(state, :slack, "owned", "shared")
    assert replacement.participant_id == recovered.id
    assert replacement.principal_id == recovered.id
    assert {:error, :not_found} = ETS.get_external_identity_binding(state, old_binding.id)
    assert {:ok, ^foreign} = ETS.get_participant(state, foreign.id)
    assert {:ok, ^foreign_binding} = ETS.get_external_identity_binding(state, :slack, "foreign", "shared")
    assert {:ok, ^recovered} = ETS.get_or_create_participant_by_external_binding(state, :slack, "owned", "shared", %{})
  end

  test "a revoked missing participant identity cannot be recreated", %{state: state} do
    {:ok, participant} =
      ETS.get_or_create_participant_by_external_binding(state, :slack, "owned", "shared", %{
        id: "revoked-person",
        type: :human
      })

    {:ok, binding} = ETS.get_external_identity_binding(state, :slack, "owned", "shared")
    revoked = ExternalIdentityBinding.revoke(binding)
    assert {:ok, ^revoked} = ETS.save_external_identity_binding(state, revoked)
    :ets.delete(state.participants, participant.id)
    before = :ets.tab2list(state.participants)

    assert {:error, :external_identity_revoked} =
             ETS.get_or_create_participant_by_external_binding(state, :slack, "owned", "shared", %{
               id: "must-not-exist",
               type: :human
             })

    assert :ets.tab2list(state.participants) == before
    assert {:ok, ^revoked} = ETS.get_external_identity_binding(state, :slack, "owned", "shared")
    assert {:error, :not_found} = ETS.get_participant(state, "must-not-exist")
  end

  test "a stale membership scope index can recover without changing another scope", %{state: state} do
    owned =
      Membership.new(%{
        id: "old-member",
        room_id: "owned",
        principal_id: "person",
        issuer_principal_id: "host",
        metadata: %{complete: "old"}
      })

    foreign =
      Membership.new(%{
        id: "foreign-member",
        room_id: "foreign",
        principal_id: "person",
        issuer_principal_id: "host",
        metadata: %{complete: "foreign"}
      })

    for record <- [owned, foreign], do: assert({:ok, record} == ETS.save_membership(state, record))
    :ets.delete(state.memberships, owned.id)
    recovered = %{owned | id: "new-member", metadata: %{complete: "recovered"}}
    assert {:ok, ^recovered} = ETS.save_membership(state, recovered)
    assert {:ok, ^recovered} = ETS.get_membership_by_scope(state, "owned", "person")
    assert {:ok, ^foreign} = ETS.get_membership_by_scope(state, "foreign", "person")
    assert {:ok, ^foreign} = ETS.get_membership(state, foreign.id)
    assert {:ok, ^recovered} = ETS.save_membership(state, recovered)
  end

  test "a stale invocation scope index can recover without a foreign policy change", %{state: state} do
    owned =
      InvocationPolicy.new(%{
        id: "old-policy",
        target_principal_id: "agent",
        issuer_principal_id: "host",
        scope: AuthorizationScope.new(%{kind: :room, room_id: "owned"}),
        mode: :nobody,
        metadata: %{complete: "old"}
      })

    foreign =
      InvocationPolicy.new(%{
        id: "foreign-policy",
        target_principal_id: "agent",
        issuer_principal_id: "host",
        scope: AuthorizationScope.new(%{kind: :room, room_id: "foreign"}),
        mode: :nobody,
        metadata: %{complete: "foreign"}
      })

    for record <- [owned, foreign], do: assert({:ok, record} == ETS.save_invocation_policy(state, record))
    :ets.delete(state.invocation_policies, owned.id)
    recovered = %{owned | id: "new-policy", metadata: %{complete: "recovered"}}
    assert {:ok, ^recovered} = ETS.save_invocation_policy(state, recovered)

    assert {:ok, ^recovered} =
             ETS.get_invocation_policy_by_scope(state, "agent", AuthorizationScope.key(recovered.scope))

    assert {:ok, ^foreign} = ETS.get_invocation_policy_by_scope(state, "agent", AuthorizationScope.key(foreign.scope))
    assert {:ok, ^foreign} = ETS.get_invocation_policy(state, foreign.id)
    assert {:ok, ^recovered} = ETS.save_invocation_policy(state, recovered)
  end
end
