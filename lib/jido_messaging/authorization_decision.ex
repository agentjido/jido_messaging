defmodule Jido.Messaging.AuthorizationDecision do
  @moduledoc """
  Ephemeral result of one durable messaging authorization check.

  A decision identifies the verified principal, effective canonical scope, and
  exact grant and invocation-policy revisions. It is not a reusable token.
  Callers must check authorization again before queued work or a later effect.
  """

  alias Jido.Messaging.AuthorizationScope

  @enforce_keys [:result, :principal_id, :action, :effective_scope, :checked_at]
  defstruct [
    :result,
    :reason,
    :principal_id,
    :action,
    :effective_scope,
    :grant_id,
    :grant_revision,
    :invocation_policy_id,
    :invocation_policy_revision,
    :valid_until,
    :checked_at,
    constraints: %{}
  ]

  @type result :: :allow | :deny
  @type t :: %__MODULE__{
          result: result(),
          reason: atom() | nil,
          principal_id: String.t(),
          action: Jido.Messaging.AuthorizationAction.t(),
          effective_scope: AuthorizationScope.t(),
          grant_id: String.t() | nil,
          grant_revision: pos_integer() | nil,
          invocation_policy_id: String.t() | nil,
          invocation_policy_revision: pos_integer() | nil,
          valid_until: DateTime.t() | nil,
          checked_at: DateTime.t(),
          constraints: map()
        }

  @doc "Converts a decision to safe integration context data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = decision) do
    %{
      result: decision.result,
      reason: decision.reason,
      verified_principal_id: decision.principal_id,
      action: decision.action,
      effective_scope: AuthorizationScope.to_map(decision.effective_scope),
      grant: revision_ref(decision.grant_id, decision.grant_revision),
      invocation_policy: revision_ref(decision.invocation_policy_id, decision.invocation_policy_revision),
      constraints: decision.constraints,
      valid_until: decision.valid_until,
      checked_at: decision.checked_at
    }
  end

  defp revision_ref(nil, nil), do: nil
  defp revision_ref(id, revision), do: %{id: id, revision: revision}
end
