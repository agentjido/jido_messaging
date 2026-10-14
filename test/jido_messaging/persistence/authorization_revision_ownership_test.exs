defmodule Jido.Messaging.Persistence.AuthorizationRevisionOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{AuthorizationScope, Grant, InvocationPolicy, Membership, Persistence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ],
      kind <- [:membership, :grant, :policy] do
    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} #{kind} keeps immutable identity and terminal revocation across exact revisions" do
      adapter = unquote(adapter)
      kind = unquote(kind)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      record = record(kind)
      assert {:error, {:invalid_initial_revision, 2}} = save(adapter, state, kind, %{record | revision: 2})
      assert {:error, :not_found} = get(adapter, state, kind, record.id)
      assert {:ok, ^record} = save(adapter, state, kind, record)
      assert {:ok, ^record} = save(adapter, state, kind, record)
      changed_identity = put_identity(kind, record)
      assert {:error, :authorization_identity_immutable} = save(adapter, state, kind, changed_identity)
      assert {:ok, ^record} = get(adapter, state, kind, record.id)
      assert {:error, {:stale_revision, 1}} = save(adapter, state, kind, %{record | revision: 3})
      suspended = %{record | revision: 2, status: :suspended}
      assert {:ok, ^suspended} = save(adapter, state, kind, suspended)
      assert {:error, {:stale_revision, 2}} = save(adapter, state, kind, record)
      revoked = %{suspended | revision: 3, status: :revoked}
      assert {:ok, ^revoked} = save(adapter, state, kind, revoked)
      assert {:ok, ^revoked} = save(adapter, state, kind, revoked)

      assert {:error, :authorization_revocation_terminal} =
               save(adapter, state, kind, %{revoked | status: :active, revision: 4})

      assert {:ok, ^revoked} = get(adapter, state, kind, record.id)
      assert {:ok, [^revoked]} = list(adapter, state, kind, record, status: :revoked)
      assert {:ok, []} = list(adapter, state, kind, record, status: :active)
      assert {:ok, []} = list(adapter, state, kind, put_identity(kind, record), [])
    end
  end

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite},
        {Persistence.Postgres, :start_postgres, :stop_postgres}
      ] do
    if adapter == Persistence.Postgres, do: @tag(:postgres)

    test "#{adapter} conflicting scope IDs cannot replace the owned membership or policy index" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      membership = record(:membership)
      policy = record(:policy)
      assert {:ok, ^membership} = adapter.save_membership(state, membership)

      assert {:error, {:membership_scope_conflict, id}} =
               adapter.save_membership(state, %{membership | id: "other-member"})

      assert id == membership.id
      assert {:ok, ^membership} = adapter.get_membership_by_scope(state, membership.room_id, membership.principal_id)
      assert {:ok, ^policy} = adapter.save_invocation_policy(state, policy)

      assert {:error, {:invocation_policy_scope_conflict, id}} =
               adapter.save_invocation_policy(state, %{policy | id: "other-policy"})

      assert id == policy.id

      assert {:ok, ^policy} =
               adapter.get_invocation_policy_by_scope(
                 state,
                 policy.target_principal_id,
                 AuthorizationScope.key(policy.scope)
               )
    end
  end

  defp record(:membership),
    do: Membership.new(%{id: "member", principal_id: "owned", room_id: "room", issuer_principal_id: "issuer"})

  defp record(:grant),
    do:
      Grant.new(%{
        id: "grant",
        principal_id: "owned",
        issuer_principal_id: "issuer",
        actions: [:read_transcript],
        scope: %{kind: :room, room_id: "room"}
      })

  defp record(:policy),
    do:
      InvocationPolicy.new(%{
        id: "policy",
        target_principal_id: "owned",
        issuer_principal_id: "issuer",
        mode: :nobody,
        scope: %{kind: :room, room_id: "room"}
      })

  defp put_identity(:membership, record), do: %{record | room_id: "foreign", revision: record.revision + 1}
  defp put_identity(:grant, record), do: %{record | principal_id: "foreign", revision: record.revision + 1}
  defp put_identity(:policy, record), do: %{record | target_principal_id: "foreign", revision: record.revision + 1}

  defp save(adapter, state, :membership, record), do: adapter.save_membership(state, record)
  defp save(adapter, state, :grant, record), do: adapter.save_principal_grant(state, record)
  defp save(adapter, state, :policy, record), do: adapter.save_invocation_policy(state, record)
  defp get(adapter, state, :membership, id), do: adapter.get_membership(state, id)
  defp get(adapter, state, :grant, id), do: adapter.get_principal_grant(state, id)
  defp get(adapter, state, :policy, id), do: adapter.get_invocation_policy(state, id)
  defp list(adapter, state, :membership, record, opts), do: adapter.list_memberships(state, record.room_id, opts)
  defp list(adapter, state, :grant, record, opts), do: adapter.list_principal_grants(state, record.principal_id, opts)

  defp list(adapter, state, :policy, record, opts),
    do: adapter.list_invocation_policies(state, record.target_principal_id, opts)
end
