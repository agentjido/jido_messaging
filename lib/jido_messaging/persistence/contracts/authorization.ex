defmodule Jido.Messaging.Persistence.Contracts.Authorization do
  @moduledoc """
  Storage contract for authorization.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.Grant
  alias Jido.Messaging.InvocationPolicy
  alias Jido.Messaging.Membership
  alias Jido.Messaging.Principal

  @type state :: Jido.Messaging.Persistence.state()
  @type room_id :: Jido.Messaging.Persistence.room_id()
  @type participant_id :: Jido.Messaging.Persistence.participant_id()

  @callback save_principal(state, Principal.t()) :: {:ok, Principal.t()} | {:error, term()}

  @callback get_principal(state, String.t()) :: {:ok, Principal.t()} | {:error, :not_found}

  @callback save_membership(state, Membership.t()) ::
              {:ok, Membership.t()} | {:error, term()}

  @callback get_membership(state, String.t()) ::
              {:ok, Membership.t()} | {:error, :not_found}

  @callback get_membership_by_scope(state, room_id(), participant_id()) ::
              {:ok, Membership.t()} | {:error, :not_found}

  @callback list_memberships(state, room_id(), keyword()) :: {:ok, [Membership.t()]}

  @callback save_principal_grant(state, Grant.t()) :: {:ok, Grant.t()} | {:error, term()}

  @callback get_principal_grant(state, String.t()) :: {:ok, Grant.t()} | {:error, :not_found}

  @callback list_principal_grants(state, participant_id(), keyword()) :: {:ok, [Grant.t()]}

  @callback save_invocation_policy(state, InvocationPolicy.t()) ::
              {:ok, InvocationPolicy.t()} | {:error, term()}

  @callback get_invocation_policy(state, String.t()) ::
              {:ok, InvocationPolicy.t()} | {:error, :not_found}

  @callback get_invocation_policy_by_scope(state, participant_id(), String.t()) ::
              {:ok, InvocationPolicy.t()} | {:error, :not_found}

  @callback list_invocation_policies(state, participant_id(), keyword()) ::
              {:ok, [InvocationPolicy.t()]}
end
