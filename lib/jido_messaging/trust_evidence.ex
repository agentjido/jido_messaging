defmodule Jido.Messaging.TrustEvidence do
  @moduledoc """
  Scoped, advisory evidence about one Jidoka agent outcome.

  This record stores factual outcome and source fields. It has no score,
  ranking, confidence, recommendation, grant, membership, prompt, output, or
  executable agent data. It cannot select or authorize an agent.
  """

  alias Jido.Messaging.{TrustEvidenceData, TrustEvidenceSource}

  @outcomes [:succeeded, :failed, :denied, :cancelled, :inconclusive]
  @verification_states [:unverified, :verified, :disputed, :revoked]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              claim_id: Zoi.string(),
              room_id: Zoi.string(),
              subject_principal_id: Zoi.string(),
              subject_jidoka_agent_ref: Zoi.map(),
              issuer_principal_id: Zoi.string(),
              capability_scope: Zoi.array(Zoi.string()),
              outcome: Zoi.enum(@outcomes),
              source: Zoi.struct(TrustEvidenceSource),
              verification_state: Zoi.enum(@verification_states),
              verification_ref: Zoi.string() |> Zoi.nullish(),
              observed_at: Zoi.struct(DateTime),
              expires_at: Zoi.struct(DateTime),
              recorded_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type outcome :: :succeeded | :failed | :denied | :cancelled | :inconclusive
  @type verification_state :: :unverified | :verified | :disputed | :revoked
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
    :room_id,
    :subject_principal_id,
    :subject_jidoka_agent_ref,
    :issuer_principal_id,
    :capability_scope,
    :outcome,
    :source,
    :verification_state,
    :verification_ref,
    :observed_at,
    :expires_at
  ]

  @doc "Returns the Zoi schema for TrustEvidence."
  def schema, do: @schema

  @doc "Builds one strict advisory evidence revision."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = TrustEvidenceData.strict_keys!(attrs, @allowed_keys, "trust evidence")
    now = DateTime.utc_now()
    source = attrs |> TrustEvidenceData.value(:source) |> TrustEvidenceSource.new()

    subject_jidoka_agent_ref =
      attrs
      |> TrustEvidenceData.value(:subject_jidoka_agent_ref)
      |> TrustEvidenceData.jidoka_ref!()

    capability_scope =
      attrs
      |> TrustEvidenceData.value(:capability_scope)
      |> TrustEvidenceData.code_list!(:capability_scope)

    verification_state =
      attrs
      |> TrustEvidenceData.value(:verification_state, :unverified)
      |> TrustEvidenceData.enum!(@verification_states, :verification_state)

    verification_ref =
      attrs
      |> TrustEvidenceData.value(:verification_ref)
      |> TrustEvidenceData.optional_ref!(:verification_ref)

    :ok = validate_verification!(verification_state, verification_ref)
    observed_at = attrs |> TrustEvidenceData.value(:observed_at) |> TrustEvidenceData.observed_at!(now)
    expires_at = attrs |> TrustEvidenceData.value(:expires_at) |> TrustEvidenceData.expiry!(observed_at)
    room_id = attrs |> TrustEvidenceData.value(:room_id) |> TrustEvidenceData.required_ref!(:room_id)

    subject_principal_id =
      attrs
      |> TrustEvidenceData.value(:subject_principal_id)
      |> TrustEvidenceData.required_ref!(:subject_principal_id)

    issuer_principal_id =
      attrs
      |> TrustEvidenceData.value(:issuer_principal_id)
      |> TrustEvidenceData.required_ref!(:issuer_principal_id)

    claim_id =
      TrustEvidenceData.stable_id("jtec", {
        1,
        room_id,
        subject_principal_id,
        subject_jidoka_agent_ref,
        issuer_principal_id,
        capability_scope,
        TrustEvidenceSource.claim_key(source)
      })

    Jido.Chat.Schema.parse!(__MODULE__, @schema, %{
      id: TrustEvidenceData.stable_id("jte", {1, claim_id, source.revision}),
      claim_id: claim_id,
      room_id: room_id,
      subject_principal_id: subject_principal_id,
      subject_jidoka_agent_ref: subject_jidoka_agent_ref,
      issuer_principal_id: issuer_principal_id,
      capability_scope: capability_scope,
      outcome: attrs |> TrustEvidenceData.value(:outcome) |> TrustEvidenceData.enum!(@outcomes, :outcome),
      source: source,
      verification_state: verification_state,
      verification_ref: verification_ref,
      observed_at: observed_at,
      expires_at: expires_at,
      recorded_at: now
    })
  end

  def new(_attrs), do: raise(ArgumentError, "trust evidence must be a plain map")

  @doc "Validates a TrustEvidence struct against its derived identities."
  @spec validate(t()) :: :ok | {:error, :invalid_trust_evidence}
  def validate(%__MODULE__{} = evidence) do
    if valid_recorded_at?(evidence.recorded_at) do
      attrs = evidence |> Map.from_struct() |> Map.drop([:id, :claim_id, :recorded_at])
      rebuilt = new(attrs)

      if rebuilt.id == evidence.id and rebuilt.claim_id == evidence.claim_id and equivalent?(rebuilt, evidence) do
        :ok
      else
        {:error, :invalid_trust_evidence}
      end
    else
      {:error, :invalid_trust_evidence}
    end
  rescue
    ArgumentError -> {:error, :invalid_trust_evidence}
  end

  def validate(_evidence), do: {:error, :invalid_trust_evidence}

  @doc "Tests whether two records contain the same immutable evidence data."
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = left, %__MODULE__{} = right) do
    Map.delete(Map.from_struct(left), :recorded_at) ==
      Map.delete(Map.from_struct(right), :recorded_at)
  end

  @doc "Tests whether evidence is current and not revoked at a time."
  @spec current_at?(t(), DateTime.t()) :: boolean()
  def current_at?(%__MODULE__{} = evidence, %DateTime{} = at) do
    evidence.verification_state != :revoked and
      DateTime.compare(at, evidence.observed_at) != :lt and
      DateTime.compare(at, evidence.expires_at) == :lt
  end

  @doc "Tests whether the factual outcome is negative evidence."
  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{outcome: outcome}), do: outcome in [:failed, :denied]

  defp validate_verification!(:unverified, nil), do: :ok

  defp validate_verification!(state, verification_ref)
       when state in [:verified, :disputed, :revoked] and is_binary(verification_ref),
       do: :ok

  defp validate_verification!(_state, _verification_ref),
    do: raise(ArgumentError, "verification state and reference do not match")

  defp valid_recorded_at?(%DateTime{} = recorded_at) do
    DateTime.compare(recorded_at, DateTime.add(DateTime.utc_now(), 300, :second)) != :gt
  end

  defp valid_recorded_at?(_recorded_at), do: false
end
