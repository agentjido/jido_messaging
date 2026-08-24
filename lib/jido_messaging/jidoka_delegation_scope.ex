defmodule Jido.Messaging.JidokaDelegationScope do
  @moduledoc """
  Exact authorization scope for one Jidoka delegation transport boundary.

  The host authorization layer builds this value only after it verifies room
  and thread access for both principals. Authorization references are opaque
  audit identifiers. They are not credentials and are not persisted in the
  delegation event.
  """

  alias Jido.Messaging.DelegationData

  @enforce_keys [
    :instance_module,
    :room_id,
    :thread_id,
    :source_principal_id,
    :target_principal_id,
    :source_authorization_refs,
    :target_authorization_refs
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          instance_module: module(),
          room_id: String.t(),
          thread_id: String.t(),
          source_principal_id: String.t(),
          target_principal_id: String.t(),
          source_authorization_refs: [String.t()],
          target_authorization_refs: [String.t()]
        }

  @allowed_keys [
    :room_id,
    :thread_id,
    :source_principal_id,
    :target_principal_id,
    :source_authorization_refs,
    :target_authorization_refs
  ]

  @doc "Builds an exact instance-bound delegation authorization scope."
  @spec new(module(), map()) :: {:ok, t()} | {:error, :invalid_jidoka_delegation_scope}
  def new(instance_module, attrs)
      when is_atom(instance_module) and not is_nil(instance_module) and is_map(attrs) and
             not is_struct(attrs) do
    {:ok, new!(instance_module, attrs)}
  rescue
    ArgumentError -> {:error, :invalid_jidoka_delegation_scope}
  end

  def new(_instance_module, _attrs), do: {:error, :invalid_jidoka_delegation_scope}

  @doc "Builds a delegation scope and raises for invalid input."
  @spec new!(module(), map()) :: t()
  def new!(instance_module, attrs)
      when is_atom(instance_module) and not is_nil(instance_module) and is_map(attrs) and
             not is_struct(attrs) do
    :ok = DelegationData.strict_keys!(attrs, @allowed_keys, "Jidoka delegation scope")

    scope = %__MODULE__{
      instance_module: instance_module,
      room_id: attrs |> DelegationData.value(:room_id) |> DelegationData.required_ref!(:room_id),
      thread_id: attrs |> DelegationData.value(:thread_id) |> DelegationData.required_ref!(:thread_id),
      source_principal_id:
        attrs |> DelegationData.value(:source_principal_id) |> DelegationData.required_ref!(:source_principal_id),
      target_principal_id:
        attrs |> DelegationData.value(:target_principal_id) |> DelegationData.required_ref!(:target_principal_id),
      source_authorization_refs:
        attrs
        |> DelegationData.value(:source_authorization_refs)
        |> DelegationData.ref_list!(:source_authorization_ref, minimum: 1, maximum: 32),
      target_authorization_refs:
        attrs
        |> DelegationData.value(:target_authorization_refs)
        |> DelegationData.ref_list!(:target_authorization_ref, minimum: 1, maximum: 32)
    }

    if scope.source_principal_id == scope.target_principal_id do
      raise ArgumentError, "delegation principals must be different"
    end

    scope
  end

  def new!(_instance_module, _attrs), do: raise(ArgumentError, "invalid Jidoka delegation scope")

  @doc "Validates a scope, including its non-empty authorization references."
  @spec validate(t()) :: :ok | {:error, :invalid_jidoka_delegation_scope}
  def validate(%__MODULE__{} = scope) do
    attrs = scope |> Map.from_struct() |> Map.delete(:instance_module)

    case new(scope.instance_module, attrs) do
      {:ok, ^scope} -> :ok
      {:ok, _normalized} -> {:error, :invalid_jidoka_delegation_scope}
      {:error, :invalid_jidoka_delegation_scope} = error -> error
    end
  end

  def validate(_scope), do: {:error, :invalid_jidoka_delegation_scope}
end
