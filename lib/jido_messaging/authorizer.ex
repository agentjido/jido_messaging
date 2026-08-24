defmodule Jido.Messaging.Authorizer do
  @moduledoc """
  Durable least-privilege authorization for messaging actions.

  `check/4` reads current persistence state on every call. It does not use
  participant type, trust evidence, display name, or Jidoka runtime policy.
  """

  alias Jido.Messaging.{
    AuthorizationAction,
    AuthorizationData,
    AuthorizationDecision,
    AuthorizationScope,
    Grant,
    InvocationPolicy,
    Membership,
    Runtime
  }

  @doc "Checks a principal action against current grants and invocation policy."
  @spec check(atom(), String.t(), AuthorizationAction.t() | String.t(), AuthorizationScope.t() | map()) ::
          {:ok, AuthorizationDecision.t()}
          | {:error, {:authorization_denied, atom(), AuthorizationDecision.t()}}
          | {:error, term()}
  def check(runtime, principal_id, action, resource) when is_atom(runtime) do
    principal_id = AuthorizationData.required_id!(principal_id, :principal_id)
    action = AuthorizationAction.normalize!(action)
    scope = AuthorizationScope.new(resource)
    checked_at = DateTime.utc_now()
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence),
         {:ok, grants} <- persistence.list_principal_grants(state, principal_id, limit: 501),
         :ok <- bounded_authorization_set(grants),
         {:ok, grant} <- select_grant(persistence, state, grants, action, scope, checked_at) do
      finish_check(persistence, state, principal_id, action, scope, grant, checked_at)
    else
      {:deny, reason, grant, policy} ->
        decision = deny_decision(principal_id, action, scope, reason, grant, policy, checked_at)
        {:error, {:authorization_denied, reason, decision}}

      {:error, _reason} = error ->
        error
    end
  rescue
    ArgumentError -> {:error, :invalid_authorization_request}
  end

  defp finish_check(persistence, state, principal_id, action, scope, grant, checked_at) do
    case authorize_invocation(persistence, state, principal_id, action, scope, checked_at) do
      {:ok, policy} ->
        {:ok, allow_decision(principal_id, action, scope, grant, policy, checked_at)}

      {:deny, reason, policy} ->
        decision = deny_decision(principal_id, action, scope, reason, grant, policy, checked_at)
        {:error, {:authorization_denied, reason, decision}}

      {:error, _reason} = error ->
        error
    end
  end

  defp select_grant(persistence, state, grants, action, scope, checked_at) do
    scoped =
      Enum.filter(grants, fn grant ->
        Grant.active_at?(grant, checked_at) and action in grant.actions and
          AuthorizationScope.contains?(grant.scope, scope)
      end)

    eligible =
      Enum.filter(scoped, fn grant ->
        not requires_membership?(grant, scope) or active_member?(persistence, state, scope.room_id, grant.principal_id)
      end)

    case Enum.max_by(eligible, &grant_rank/1, fn -> nil end) do
      nil when scoped != [] -> {:deny, :membership_required, nil, nil}
      nil -> {:deny, :no_matching_grant, nil, nil}
      grant -> {:ok, grant}
    end
  end

  defp authorize_invocation(_persistence, _state, _principal_id, action, _scope, _at)
       when action != :invoke_agent,
       do: {:ok, nil}

  defp authorize_invocation(persistence, state, principal_id, :invoke_agent, scope, checked_at) do
    case scope.target_principal_id do
      nil ->
        {:deny, :invocation_target_required, nil}

      target_principal_id ->
        with {:ok, policies} <- persistence.list_invocation_policies(state, target_principal_id, limit: 501),
             :ok <- bounded_authorization_set(policies),
             {:ok, policy} <- select_policy(policies, scope, checked_at),
             :ok <- evaluate_policy(persistence, state, policy, principal_id, scope) do
          {:ok, policy}
        else
          {:deny, reason, policy} -> {:deny, reason, policy}
          {:error, _reason} = error -> error
        end
    end
  end

  defp select_policy(policies, scope, checked_at) do
    eligible =
      Enum.filter(policies, fn policy ->
        InvocationPolicy.active_at?(policy, checked_at) and
          AuthorizationScope.contains?(policy.scope, scope)
      end)

    case Enum.max_by(eligible, &policy_rank/1, fn -> nil end) do
      nil -> {:deny, :invocation_policy_required, nil}
      policy -> {:ok, policy}
    end
  end

  defp evaluate_policy(_persistence, _state, %{mode: :anyone}, _principal_id, _scope), do: :ok

  defp evaluate_policy(_persistence, _state, %{mode: :nobody} = policy, _principal_id, _scope),
    do: {:deny, :invocation_policy_denied, policy}

  defp evaluate_policy(_persistence, _state, %{mode: :controller_only} = policy, principal_id, _scope) do
    if policy.controller_principal_id == principal_id,
      do: :ok,
      else: {:deny, :invocation_policy_denied, policy}
  end

  defp evaluate_policy(_persistence, _state, %{mode: :allowlist} = policy, principal_id, _scope) do
    if principal_id in policy.allowed_principal_ids,
      do: :ok,
      else: {:deny, :invocation_policy_denied, policy}
  end

  defp evaluate_policy(persistence, state, %{mode: :room_members} = policy, principal_id, scope) do
    if active_member?(persistence, state, scope.room_id, principal_id),
      do: :ok,
      else: {:deny, :invocation_policy_denied, policy}
  end

  defp allow_decision(principal_id, action, scope, grant, policy, checked_at) do
    %AuthorizationDecision{
      result: :allow,
      principal_id: principal_id,
      action: action,
      effective_scope: scope,
      grant_id: grant.id,
      grant_revision: grant.revision,
      invocation_policy_id: policy && policy.id,
      invocation_policy_revision: policy && policy.revision,
      constraints: grant.constraints,
      valid_until: earliest_expiry(grant.expires_at, policy && policy.expires_at),
      checked_at: checked_at
    }
  end

  defp deny_decision(principal_id, action, scope, reason, grant, policy, checked_at) do
    %AuthorizationDecision{
      result: :deny,
      reason: reason,
      principal_id: principal_id,
      action: action,
      effective_scope: scope,
      grant_id: grant && grant.id,
      grant_revision: grant && grant.revision,
      invocation_policy_id: policy && policy.id,
      invocation_policy_revision: policy && policy.revision,
      checked_at: checked_at
    }
  end

  defp active_member?(_persistence, _state, nil, _principal_id), do: false

  defp active_member?(persistence, state, room_id, principal_id) do
    match?(
      {:ok, %Membership{status: :active}},
      persistence.get_membership_by_scope(state, room_id, principal_id)
    )
  end

  defp requires_membership?(grant, scope) do
    scope.room_id != nil and Map.get(grant.constraints, "requires_membership", true)
  end

  defp grant_rank(grant),
    do: {AuthorizationScope.specificity(grant.scope), grant.revision, DateTime.to_unix(grant.inserted_at, :microsecond)}

  defp policy_rank(policy),
    do:
      {AuthorizationScope.specificity(policy.scope), policy.revision,
       DateTime.to_unix(policy.inserted_at, :microsecond)}

  defp earliest_expiry(nil, nil), do: nil
  defp earliest_expiry(%DateTime{} = first, nil), do: first
  defp earliest_expiry(nil, %DateTime{} = second), do: second

  defp earliest_expiry(%DateTime{} = first, %DateTime{} = second) do
    if DateTime.compare(first, second) == :lt, do: first, else: second
  end

  defp require_callbacks(persistence) do
    callbacks = [
      list_principal_grants: 3,
      get_membership_by_scope: 3,
      list_invocation_policies: 3
    ]

    if Enum.all?(callbacks, fn {name, arity} -> function_exported?(persistence, name, arity) end),
      do: :ok,
      else: {:error, :unsupported}
  end

  defp bounded_authorization_set(records) when length(records) <= 500, do: :ok
  defp bounded_authorization_set(_records), do: {:error, :authorization_set_too_large}
end
