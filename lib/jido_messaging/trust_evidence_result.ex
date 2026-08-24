defmodule Jido.Messaging.TrustEvidenceResult do
  @moduledoc """
  Explainable result for one scoped trust-evidence query.

  `:no_evidence` means that the provider was available but returned no current
  matching evidence. `:unavailable` means that the provider could not answer.
  A result with evidence lists every factual outcome that is present. It does
  not calculate a score, rank, recommendation, or selection decision.
  """

  alias Jido.Messaging.{TrustEvidence, TrustEvidenceData}

  @enforce_keys [
    :status,
    :provider_id,
    :evidence,
    :outcomes_present,
    :reason_code,
    :queried_at
  ]
  defstruct @enforce_keys

  @type status :: :evidence | :no_evidence | :unavailable
  @type t :: %__MODULE__{
          status: status(),
          provider_id: String.t(),
          evidence: [TrustEvidence.t()],
          outcomes_present: [TrustEvidence.outcome()],
          reason_code: String.t() | nil,
          queried_at: DateTime.t()
        }

  @doc "Builds an available result from validated evidence."
  @spec available(String.t(), [TrustEvidence.t()], DateTime.t()) :: t()
  def available(provider_id, evidence, queried_at \\ DateTime.utc_now())
      when is_list(evidence) and is_struct(queried_at, DateTime) do
    provider_id = TrustEvidenceData.required_ref!(provider_id, :provider_id)

    if not Enum.all?(evidence, &match?(%TrustEvidence{}, &1)) do
      raise ArgumentError, "trust evidence result contains invalid evidence"
    end

    status = if evidence == [], do: :no_evidence, else: :evidence

    %__MODULE__{
      status: status,
      provider_id: provider_id,
      evidence: evidence,
      outcomes_present: evidence |> Enum.map(& &1.outcome) |> Enum.uniq() |> Enum.sort(),
      reason_code: nil,
      queried_at: queried_at
    }
  end

  @doc "Builds an unavailable result without exposing a raw provider error."
  @spec unavailable(String.t(), String.t(), DateTime.t()) :: t()
  def unavailable(provider_id, reason_code, queried_at \\ DateTime.utc_now())
      when is_struct(queried_at, DateTime) do
    %__MODULE__{
      status: :unavailable,
      provider_id: TrustEvidenceData.required_ref!(provider_id, :provider_id),
      evidence: [],
      outcomes_present: [],
      reason_code: TrustEvidenceData.code!(reason_code, :reason_code),
      queried_at: queried_at
    }
  end

  @doc "Returns the negative factual evidence without making a selection."
  @spec negative_evidence(t()) :: [TrustEvidence.t()]
  def negative_evidence(%__MODULE__{} = result), do: Enum.filter(result.evidence, &TrustEvidence.negative?/1)
end
