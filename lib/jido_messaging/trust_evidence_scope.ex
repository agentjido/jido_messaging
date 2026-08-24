defmodule Jido.Messaging.TrustEvidenceScope do
  @moduledoc """
  Exact authorization and membership scope for advisory evidence.

  The host builds this value after it checks that the requester can read the
  room and that the Jidoka agent subject is a current room member. The opaque
  references are attestations from that host check. They are not credentials
  and are not stored with evidence.
  """

  alias Jido.Messaging.TrustEvidenceData

  @enforce_keys [
    :instance_module,
    :room_id,
    :requester_principal_id,
    :subject_principal_id,
    :subject_jidoka_agent_ref,
    :requester_authorization_refs,
    :subject_membership_refs
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          instance_module: module(),
          room_id: String.t(),
          requester_principal_id: String.t(),
          subject_principal_id: String.t(),
          subject_jidoka_agent_ref: map(),
          requester_authorization_refs: [String.t()],
          subject_membership_refs: [String.t()]
        }

  @allowed_keys [
    :room_id,
    :requester_principal_id,
    :subject_principal_id,
    :subject_jidoka_agent_ref,
    :requester_authorization_refs,
    :subject_membership_refs
  ]

  @doc "Builds an exact instance-bound evidence scope."
  @spec new(module(), map()) :: {:ok, t()} | {:error, :invalid_trust_evidence_scope}
  def new(instance_module, attrs)
      when is_atom(instance_module) and not is_nil(instance_module) and is_map(attrs) and
             not is_struct(attrs) do
    {:ok, new!(instance_module, attrs)}
  rescue
    ArgumentError -> {:error, :invalid_trust_evidence_scope}
  end

  def new(_instance_module, _attrs), do: {:error, :invalid_trust_evidence_scope}

  @doc "Builds an evidence scope and raises for invalid input."
  @spec new!(module(), map()) :: t()
  def new!(instance_module, attrs)
      when is_atom(instance_module) and not is_nil(instance_module) and is_map(attrs) and
             not is_struct(attrs) do
    :ok = TrustEvidenceData.strict_keys!(attrs, @allowed_keys, "trust evidence scope")

    %__MODULE__{
      instance_module: instance_module,
      room_id: attrs |> TrustEvidenceData.value(:room_id) |> TrustEvidenceData.required_ref!(:room_id),
      requester_principal_id:
        attrs
        |> TrustEvidenceData.value(:requester_principal_id)
        |> TrustEvidenceData.required_ref!(:requester_principal_id),
      subject_principal_id:
        attrs
        |> TrustEvidenceData.value(:subject_principal_id)
        |> TrustEvidenceData.required_ref!(:subject_principal_id),
      subject_jidoka_agent_ref:
        attrs
        |> TrustEvidenceData.value(:subject_jidoka_agent_ref)
        |> TrustEvidenceData.jidoka_ref!(),
      requester_authorization_refs:
        attrs
        |> TrustEvidenceData.value(:requester_authorization_refs)
        |> TrustEvidenceData.ref_list!(:requester_authorization_ref),
      subject_membership_refs:
        attrs
        |> TrustEvidenceData.value(:subject_membership_refs)
        |> TrustEvidenceData.ref_list!(:subject_membership_ref)
    }
  end

  def new!(_instance_module, _attrs), do: raise(ArgumentError, "invalid trust evidence scope")

  @doc "Validates a scope, including its non-empty attestation references."
  @spec validate(t()) :: :ok | {:error, :invalid_trust_evidence_scope}
  def validate(%__MODULE__{} = scope) do
    attrs = scope |> Map.from_struct() |> Map.delete(:instance_module)

    case new(scope.instance_module, attrs) do
      {:ok, ^scope} -> :ok
      {:ok, _normalized} -> {:error, :invalid_trust_evidence_scope}
      {:error, :invalid_trust_evidence_scope} = error -> error
    end
  end

  def validate(_scope), do: {:error, :invalid_trust_evidence_scope}
end
