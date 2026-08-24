defmodule Jido.Messaging.AccessControl do
  @moduledoc false

  alias Jido.Messaging.{AuthorizationScope, Grant, InvocationPolicy, Membership, Runtime, Thread}

  @doc false
  @spec create_membership(atom(), map()) :: {:ok, Membership.t()} | {:error, term()}
  def create_membership(runtime, attrs) when is_map(attrs) do
    membership = Membership.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, save_membership: 2, get_membership_by_scope: 3),
         {:ok, _principal} <- persistence.get_participant(state, membership.principal_id),
         {:ok, _room} <- persistence.get_room(state, membership.room_id),
         :ok <- ensure_initial_revision(membership.revision),
         :ok <- ensure_initial_status(membership.status),
         {:ok, membership} <- get_or_create_membership(persistence, state, membership) do
      {:ok, membership}
    end
  end

  @doc false
  @spec get_membership(atom(), String.t()) :: {:ok, Membership.t()} | {:error, term()}
  def get_membership(runtime, membership_id) when is_binary(membership_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_membership, 2) do
      persistence.get_membership(state, membership_id)
    end
  end

  @doc false
  @spec list_memberships(atom(), String.t(), keyword()) :: {:ok, [Membership.t()]} | {:error, term()}
  def list_memberships(runtime, room_id, opts) when is_binary(room_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :list_memberships, 3) do
      persistence.list_memberships(state, room_id, opts)
    end
  end

  @doc false
  @spec transition_membership(atom(), String.t(), pos_integer(), Membership.status()) ::
          {:ok, Membership.t()} | {:error, term()}
  def transition_membership(runtime, membership_id, expected_revision, status)
      when is_binary(membership_id) and is_integer(expected_revision) and
             status in [:active, :suspended, :revoked] do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_membership, 2),
         {:ok, membership} <- get_membership(runtime, membership_id),
         :ok <- expected_revision(membership, expected_revision),
         revised = Membership.transition(membership, status) do
      persistence.save_membership(state, revised)
    end
  end

  @doc false
  @spec create_grant(atom(), map()) :: {:ok, Grant.t()} | {:error, term()}
  def create_grant(runtime, attrs) when is_map(attrs) do
    grant = Grant.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_principal_grant, 2),
         {:ok, _principal} <- persistence.get_participant(state, grant.principal_id),
         :ok <- validate_scope(persistence, state, grant.scope),
         :ok <- ensure_initial_revision(grant.revision),
         :ok <- ensure_initial_status(grant.status) do
      persistence.save_principal_grant(state, grant)
    end
  end

  @doc false
  @spec get_grant(atom(), String.t()) :: {:ok, Grant.t()} | {:error, term()}
  def get_grant(runtime, grant_id) when is_binary(grant_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_principal_grant, 2) do
      persistence.get_principal_grant(state, grant_id)
    end
  end

  @doc false
  @spec list_grants(atom(), String.t(), keyword()) :: {:ok, [Grant.t()]} | {:error, term()}
  def list_grants(runtime, principal_id, opts) when is_binary(principal_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :list_principal_grants, 3) do
      persistence.list_principal_grants(state, principal_id, opts)
    end
  end

  @doc false
  @spec revise_grant(atom(), String.t(), pos_integer(), map()) :: {:ok, Grant.t()} | {:error, term()}
  def revise_grant(runtime, grant_id, expected_revision, attrs)
      when is_binary(grant_id) and is_integer(expected_revision) and is_map(attrs) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_principal_grant, 2),
         {:ok, grant} <- get_grant(runtime, grant_id),
         :ok <- expected_revision(grant, expected_revision),
         revised = Grant.revise(grant, attrs),
         :ok <- validate_scope(persistence, state, revised.scope) do
      persistence.save_principal_grant(state, revised)
    end
  end

  @doc false
  @spec revoke_grant(atom(), String.t(), pos_integer()) :: {:ok, Grant.t()} | {:error, term()}
  def revoke_grant(runtime, grant_id, expected_revision)
      when is_binary(grant_id) and is_integer(expected_revision) do
    revise_grant(runtime, grant_id, expected_revision, %{status: :revoked})
  end

  @doc false
  @spec create_invocation_policy(atom(), map()) :: {:ok, InvocationPolicy.t()} | {:error, term()}
  def create_invocation_policy(runtime, attrs) when is_map(attrs) do
    policy = InvocationPolicy.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <-
           require_callbacks(persistence,
             save_invocation_policy: 2,
             get_invocation_policy_by_scope: 3
           ),
         {:ok, _principal} <- persistence.get_participant(state, policy.target_principal_id),
         :ok <- validate_scope(persistence, state, policy.scope),
         :ok <- ensure_initial_revision(policy.revision),
         :ok <- ensure_initial_status(policy.status),
         {:error, :not_found} <-
           persistence.get_invocation_policy_by_scope(
             state,
             policy.target_principal_id,
             AuthorizationScope.key(policy.scope)
           ) do
      persistence.save_invocation_policy(state, policy)
    else
      {:ok, existing} -> {:error, {:invocation_policy_conflict, existing.id}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec get_invocation_policy(atom(), String.t()) :: {:ok, InvocationPolicy.t()} | {:error, term()}
  def get_invocation_policy(runtime, policy_id) when is_binary(policy_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :get_invocation_policy, 2) do
      persistence.get_invocation_policy(state, policy_id)
    end
  end

  @doc false
  @spec list_invocation_policies(atom(), String.t(), keyword()) ::
          {:ok, [InvocationPolicy.t()]} | {:error, term()}
  def list_invocation_policies(runtime, target_principal_id, opts)
      when is_binary(target_principal_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :list_invocation_policies, 3) do
      persistence.list_invocation_policies(state, target_principal_id, opts)
    end
  end

  @doc false
  @spec revise_invocation_policy(atom(), String.t(), pos_integer(), map()) ::
          {:ok, InvocationPolicy.t()} | {:error, term()}
  def revise_invocation_policy(runtime, policy_id, expected_revision, attrs)
      when is_binary(policy_id) and is_integer(expected_revision) and is_map(attrs) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callback(persistence, :save_invocation_policy, 2),
         {:ok, policy} <- get_invocation_policy(runtime, policy_id),
         :ok <- expected_revision(policy, expected_revision),
         revised = InvocationPolicy.revise(policy, attrs),
         :ok <- validate_scope(persistence, state, revised.scope) do
      persistence.save_invocation_policy(state, revised)
    end
  end

  @doc false
  @spec revoke_invocation_policy(atom(), String.t(), pos_integer()) ::
          {:ok, InvocationPolicy.t()} | {:error, term()}
  def revoke_invocation_policy(runtime, policy_id, expected_revision)
      when is_binary(policy_id) and is_integer(expected_revision) do
    revise_invocation_policy(runtime, policy_id, expected_revision, %{status: :revoked})
  end

  defp get_or_create_membership(persistence, state, membership) do
    case persistence.get_membership_by_scope(state, membership.room_id, membership.principal_id) do
      {:ok, %Membership{status: :active} = existing} ->
        {:ok, existing}

      {:ok, %Membership{status: status}} ->
        {:error, {:membership_inactive, status}}

      {:error, :not_found} ->
        case persistence.save_membership(state, membership) do
          {:error, {:membership_scope_conflict, _id}} ->
            persistence.get_membership_by_scope(state, membership.room_id, membership.principal_id)

          result ->
            result
        end
    end
  end

  defp validate_scope(_persistence, _state, %AuthorizationScope{kind: :bridge}), do: :ok

  defp validate_scope(persistence, state, %AuthorizationScope{kind: :room, room_id: room_id}),
    do: existing(persistence.get_room(state, room_id))

  defp validate_scope(persistence, state, %AuthorizationScope{kind: :thread} = scope) do
    with {:ok, %Thread{room_id: room_id}} <- persistence.get_thread(state, scope.thread_id),
         true <- room_id == scope.room_id do
      :ok
    else
      false -> {:error, :authorization_scope_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_scope(persistence, state, %AuthorizationScope{kind: :message} = scope) do
    with {:ok, message} <- persistence.get_message(state, scope.message_id),
         true <- message.room_id == scope.room_id,
         true <- is_nil(scope.thread_id) or message.thread_id == scope.thread_id do
      :ok
    else
      false -> {:error, :authorization_scope_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_scope(persistence, state, %AuthorizationScope{kind: :transcript} = scope) do
    case scope.thread_id do
      nil -> existing(persistence.get_room(state, scope.room_id))
      _thread_id -> validate_scope(persistence, state, %{scope | kind: :thread})
    end
  end

  defp existing({:ok, _record}), do: :ok
  defp existing({:error, _reason} = error), do: error

  defp expected_revision(%{revision: revision}, revision), do: :ok
  defp expected_revision(%{revision: revision}, _expected), do: {:error, {:stale_revision, revision}}

  defp ensure_initial_revision(1), do: :ok
  defp ensure_initial_revision(revision), do: {:error, {:invalid_initial_revision, revision}}
  defp ensure_initial_status(:active), do: :ok
  defp ensure_initial_status(status), do: {:error, {:invalid_initial_status, status}}

  defp require_callbacks(persistence, callbacks) do
    Enum.reduce_while(callbacks, :ok, fn {name, arity}, :ok ->
      case require_callback(persistence, name, arity) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp require_callback(persistence, name, arity) do
    if function_exported?(persistence, name, arity), do: :ok, else: {:error, :unsupported}
  end
end
