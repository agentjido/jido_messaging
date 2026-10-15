defmodule Jido.Messaging.Persistence.RoomAuthorityCleanupTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{AuthorizationScope, Grant, InvocationPolicy, Membership, Persistence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} room deletion removes only its owned authority records" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      participant = Participant.new(%{id: "shared-principal", type: :human})
      assert {:ok, ^participant} = adapter.save_participant(state, participant)

      records =
        for id <- ["owned-room", "foreign-room"] do
          room = Room.new(%{id: id, type: :group})
          assert {:ok, ^room} = adapter.save_room(state, room)
          scope = AuthorizationScope.new(%{kind: :room, room_id: id})

          membership =
            Membership.new(%{
              id: "membership:" <> id,
              principal_id: participant.id,
              room_id: id,
              issuer_principal_id: "host"
            })

          grant =
            Grant.new(%{
              id: "grant:" <> id,
              principal_id: participant.id,
              issuer_principal_id: "host",
              actions: [:post_message],
              scope: scope,
              constraints: %{requires_membership: true}
            })

          policy =
            InvocationPolicy.new(%{
              id: "policy:" <> id,
              target_principal_id: participant.id,
              issuer_principal_id: "host",
              scope: scope,
              mode: :room_members
            })

          assert {:ok, ^membership} = adapter.save_membership(state, membership)
          assert {:ok, ^grant} = adapter.save_principal_grant(state, grant)
          assert {:ok, ^policy} = adapter.save_invocation_policy(state, policy)
          {room, membership, grant, policy}
        end

      [
        {owned, owned_membership, owned_grant, owned_policy},
        {foreign, foreign_membership, foreign_grant, foreign_policy}
      ] = records

      assert :ok = adapter.delete_room(state, owned.id)
      assert {:error, :not_found} = adapter.get_room(state, owned.id)
      assert {:error, :not_found} = adapter.get_membership(state, owned_membership.id)
      assert {:error, :not_found} = adapter.get_principal_grant(state, owned_grant.id)
      assert {:error, :not_found} = adapter.get_invocation_policy(state, owned_policy.id)
      assert {:ok, []} = adapter.list_memberships(state, owned.id)
      assert {:ok, ^foreign} = adapter.get_room(state, foreign.id)
      assert {:ok, ^foreign_membership} = adapter.get_membership(state, foreign_membership.id)
      assert {:ok, ^foreign_grant} = adapter.get_principal_grant(state, foreign_grant.id)
      assert {:ok, ^foreign_policy} = adapter.get_invocation_policy(state, foreign_policy.id)
      assert {:ok, [^foreign_grant]} = adapter.list_principal_grants(state, participant.id)
      assert {:ok, [^foreign_policy]} = adapter.list_invocation_policies(state, participant.id)
      assert {:ok, ^participant} = adapter.get_participant(state, participant.id)
      assert :ok = adapter.delete_participant(state, participant.id)
      assert {:error, :not_found} = adapter.get_participant(state, participant.id)
      assert {:error, :not_found} = adapter.get_membership(state, foreign_membership.id)
      assert {:error, :not_found} = adapter.get_principal_grant(state, foreign_grant.id)
      assert {:error, :not_found} = adapter.get_invocation_policy(state, foreign_policy.id)
      assert {:ok, []} = adapter.list_principal_grants(state, participant.id)
      assert {:ok, []} = adapter.list_invocation_policies(state, participant.id)
      assert {:ok, ^foreign} = adapter.get_room(state, foreign.id)
    end
  end
end
