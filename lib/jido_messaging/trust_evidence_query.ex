defmodule Jido.Messaging.TrustEvidenceQuery do
  @moduledoc false

  alias Jido.Messaging.{TrustEvidence, TrustEvidenceData}

  @verification_states [:unverified, :verified, :disputed, :revoked]
  @allowed_options [
    :provider,
    :provider_opts,
    :limit,
    :capability,
    :verification_states,
    :include_expired,
    :include_history,
    :as_of
  ]

  @max_provider_records 500

  @type t :: %{
          provider: module() | nil,
          provider_opts: keyword(),
          limit: pos_integer(),
          capability: String.t() | nil,
          verification_states: [TrustEvidence.verification_state()],
          include_expired: boolean(),
          include_history: boolean(),
          as_of: DateTime.t()
        }

  @doc false
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_trust_evidence_query}
  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: build(opts), else: {:error, :invalid_trust_evidence_query}
  rescue
    ArgumentError -> {:error, :invalid_trust_evidence_query}
  end

  def new(_opts), do: {:error, :invalid_trust_evidence_query}

  defp build(opts) do
    keys = Keyword.keys(opts)

    with true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, provider} <- provider(Keyword.get(opts, :provider)),
         {:ok, provider_opts} <- provider_opts(Keyword.get(opts, :provider_opts, [])),
         {:ok, limit} <- limit(Keyword.get(opts, :limit, 50)),
         {:ok, capability} <- capability(Keyword.get(opts, :capability)),
         {:ok, verification_states} <-
           verification_states(Keyword.get(opts, :verification_states, [:unverified, :verified, :disputed])),
         {:ok, include_expired} <- boolean(Keyword.get(opts, :include_expired, false)),
         {:ok, include_history} <- boolean(Keyword.get(opts, :include_history, false)),
         {:ok, as_of} <- as_of(Keyword.get(opts, :as_of, DateTime.utc_now())) do
      {:ok,
       %{
         provider: provider,
         provider_opts: provider_opts,
         limit: limit,
         capability: capability,
         verification_states: verification_states,
         include_expired: include_expired,
         include_history: include_history,
         as_of: as_of
       }}
    else
      _invalid -> {:error, :invalid_trust_evidence_query}
    end
  end

  @doc false
  @spec apply([TrustEvidence.t()], t()) :: [TrustEvidence.t()]
  def apply(evidence, query) when is_list(evidence) and is_map(query) do
    evidence
    |> Enum.filter(&(DateTime.compare(&1.observed_at, query.as_of) != :gt))
    |> maybe_latest(query.include_history)
    |> Enum.filter(&capability_match?(&1, query.capability))
    |> Enum.filter(&(&1.verification_state in query.verification_states))
    |> Enum.filter(&(query.include_expired or DateTime.compare(query.as_of, &1.expires_at) == :lt))
    |> Enum.sort_by(&evidence_order/1, :desc)
    |> Enum.take(query.limit)
  end

  @doc false
  @spec maximum_provider_records() :: pos_integer()
  def maximum_provider_records, do: @max_provider_records

  defp maybe_latest(evidence, true), do: evidence

  defp maybe_latest(evidence, false) do
    evidence
    |> Enum.reduce(%{}, fn item, by_claim ->
      Map.update(by_claim, item.claim_id, item, fn stored ->
        if item.source.revision > stored.source.revision, do: item, else: stored
      end)
    end)
    |> Map.values()
  end

  defp capability_match?(_evidence, nil), do: true
  defp capability_match?(evidence, capability), do: capability in evidence.capability_scope

  defp evidence_order(evidence) do
    {DateTime.to_unix(evidence.observed_at, :microsecond), evidence.source.revision, evidence.id}
  end

  defp provider(nil), do: {:ok, nil}
  defp provider(module) when is_atom(module) and not is_nil(module), do: {:ok, module}
  defp provider(_module), do: :error

  defp provider_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: :error
  end

  defp provider_opts(_opts), do: :error

  defp limit(value) when is_integer(value) and value > 0 and value <= 100, do: {:ok, value}
  defp limit(_value), do: :error

  defp capability(nil), do: {:ok, nil}
  defp capability(value), do: {:ok, TrustEvidenceData.code!(value, :capability)}

  defp verification_states(values) when is_list(values) and values != [] do
    normalized =
      values
      |> Enum.map(&TrustEvidenceData.enum!(&1, @verification_states, :verification_state))
      |> Enum.uniq()

    {:ok, normalized}
  end

  defp verification_states(_values), do: :error

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: :error

  defp as_of(%DateTime{} = value), do: {:ok, value}
  defp as_of(_value), do: :error
end
