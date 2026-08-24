defmodule Jido.Messaging.TrustEvidenceService do
  @moduledoc """
  Scoped storage and provider boundary for advisory trust evidence.

  This service validates room access attestations, subject identity, issuer
  identity, message sources, provider results, and expiry. It does not rank,
  select, start, invoke, or authorize a Jidoka agent.
  """

  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    Message,
    Runtime,
    TrustEvidence,
    TrustEvidenceData,
    TrustEvidenceQuery,
    TrustEvidenceResult,
    TrustEvidenceScope
  }

  @stored_provider_id "jido_messaging:stored"

  @doc "Records one evidence revision after exact scope and source checks."
  @spec record(module(), GenServer.server(), map(), TrustEvidenceScope.t()) ::
          {:ok, TrustEvidence.t()} | {:error, term()}
  def record(instance_module, runtime, attrs, scope)
      when is_atom(instance_module) and not is_nil(instance_module) and is_map(attrs) do
    evidence = TrustEvidence.new(attrs)

    with :ok <- validate_record_scope(instance_module, scope, evidence),
         {persistence, state} <- Runtime.get_persistence(runtime),
         :ok <- ensure_persistence(persistence),
         {:ok, _room} <- persistence.get_room(state, evidence.room_id),
         {:ok, %Participant{} = subject} <-
           persistence.get_participant(state, evidence.subject_principal_id),
         :ok <- validate_agent_subject(subject),
         {:ok, %Participant{} = issuer} <-
           persistence.get_participant(state, evidence.issuer_principal_id),
         :ok <- validate_distinct_issuer(subject, issuer),
         :ok <- validate_source(persistence, state, evidence) do
      persistence.save_trust_evidence(state, evidence)
    end
  rescue
    ArgumentError -> {:error, :invalid_trust_evidence}
  end

  def record(_instance_module, _runtime, _attrs, _scope), do: {:error, :invalid_trust_evidence}

  @doc "Queries stored or host-selected provider evidence without making a selection."
  @spec query(module(), GenServer.server(), TrustEvidenceScope.t(), keyword()) ::
          {:ok, TrustEvidenceResult.t()} | {:error, term()}
  def query(instance_module, runtime, scope, opts \\ [])

  def query(instance_module, runtime, scope, opts)
      when is_atom(instance_module) and not is_nil(instance_module) and is_list(opts) do
    with :ok <- validate_scope_instance(instance_module, scope),
         {:ok, query} <- TrustEvidenceQuery.new(opts),
         {persistence, state} <- Runtime.get_persistence(runtime),
         {:ok, _room} <- persistence.get_room(state, scope.room_id),
         {:ok, %Participant{}} <- persistence.get_participant(state, scope.requester_principal_id),
         {:ok, %Participant{} = subject} <- persistence.get_participant(state, scope.subject_principal_id),
         :ok <- validate_agent_subject(subject) do
      query_source(persistence, state, scope, query)
    end
  rescue
    ArgumentError -> {:error, :invalid_trust_evidence_query}
  end

  def query(_instance_module, _runtime, _scope, _opts), do: {:error, :invalid_trust_evidence_query}

  defp query_source(persistence, state, scope, %{provider: nil} = query) do
    if list_persistence_supported?(persistence) do
      case persistence.list_trust_evidence(
             state,
             scope.subject_principal_id,
             scope.room_id,
             limit: TrustEvidenceQuery.maximum_provider_records() + 1
           ) do
        {:ok, evidence} ->
          build_available_result(persistence, state, scope, query, @stored_provider_id, evidence)

        {:error, _reason} ->
          {:ok, TrustEvidenceResult.unavailable(@stored_provider_id, "persistence.unavailable")}

        _invalid ->
          {:ok, TrustEvidenceResult.unavailable(@stored_provider_id, "persistence.invalid_result")}
      end
    else
      {:ok, TrustEvidenceResult.unavailable(@stored_provider_id, "persistence.unsupported")}
    end
  end

  defp query_source(persistence, state, scope, %{provider: provider} = query) do
    case call_provider(provider, scope, query.provider_opts) do
      {:ok, provider_id, evidence} ->
        build_available_result(persistence, state, scope, query, provider_id, evidence)

      {:unavailable, provider_id, reason_code} ->
        {:ok, TrustEvidenceResult.unavailable(provider_id, reason_code)}
    end
  end

  defp build_available_result(persistence, state, scope, query, provider_id, evidence)
       when is_list(evidence) do
    cond do
      length(evidence) > TrustEvidenceQuery.maximum_provider_records() ->
        {:ok, TrustEvidenceResult.unavailable(provider_id, "provider.result_too_large")}

      true ->
        with :ok <- validate_provider_evidence(persistence, state, scope, evidence) do
          evidence = TrustEvidenceQuery.apply(evidence, query)
          {:ok, TrustEvidenceResult.available(provider_id, evidence)}
        else
          {:error, _reason} ->
            {:ok, TrustEvidenceResult.unavailable(provider_id, "provider.invalid_result")}
        end
    end
  end

  defp build_available_result(_persistence, _state, _scope, _query, provider_id, _evidence) do
    {:ok, TrustEvidenceResult.unavailable(provider_id, "provider.invalid_result")}
  end

  defp call_provider(provider, scope, provider_opts) do
    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :id, 0),
         true <- function_exported?(provider, :query, 2),
         provider_id when is_binary(provider_id) <- provider.id() do
      provider_id = TrustEvidenceData.required_ref!(provider_id, :provider_id)

      case provider.query(scope, provider_opts) do
        {:ok, evidence} when is_list(evidence) ->
          {:ok, provider_id, evidence}

        {:error, _reason} ->
          {:unavailable, provider_id, "provider.unavailable"}

        _invalid ->
          {:unavailable, provider_id, "provider.invalid_result"}
      end
    else
      false -> {:unavailable, external_provider_id(provider), "provider.invalid"}
      _invalid -> {:unavailable, external_provider_id(provider), "provider.invalid_result"}
    end
  rescue
    _exception -> {:unavailable, external_provider_id(provider), "provider.unavailable"}
  catch
    _kind, _reason -> {:unavailable, external_provider_id(provider), "provider.unavailable"}
  end

  defp validate_provider_evidence(persistence, state, scope, evidence) do
    with true <- Enum.all?(evidence, &match?(%TrustEvidence{}, &1)),
         :ok <- validate_evidence_records(scope, evidence),
         :ok <- validate_evidence_issuers(persistence, state, evidence) do
      :ok
    else
      false -> {:error, :invalid_provider_evidence}
      {:error, _reason} = error -> error
    end
  end

  defp validate_evidence_records(scope, evidence) do
    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      exact_scope? =
        item.room_id == scope.room_id and
          item.subject_principal_id == scope.subject_principal_id and
          item.subject_jidoka_agent_ref == scope.subject_jidoka_agent_ref and
          item.issuer_principal_id != item.subject_principal_id

      case {TrustEvidence.validate(item), exact_scope?} do
        {:ok, true} -> {:cont, :ok}
        _invalid -> {:halt, {:error, :trust_evidence_scope_violation}}
      end
    end)
  end

  defp validate_evidence_issuers(persistence, state, evidence) do
    evidence
    |> Enum.map(& &1.issuer_principal_id)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn issuer_id, :ok ->
      case persistence.get_participant(state, issuer_id) do
        {:ok, %Participant{}} -> {:cont, :ok}
        _missing -> {:halt, {:error, :trust_evidence_issuer_not_found}}
      end
    end)
  end

  defp validate_record_scope(instance_module, scope, evidence) do
    with :ok <- validate_scope_instance(instance_module, scope) do
      if evidence.room_id == scope.room_id and
           evidence.subject_principal_id == scope.subject_principal_id and
           evidence.subject_jidoka_agent_ref == scope.subject_jidoka_agent_ref and
           evidence.issuer_principal_id == scope.requester_principal_id do
        :ok
      else
        {:error, :trust_evidence_scope_violation}
      end
    end
  end

  defp validate_scope_instance(
         instance_module,
         %TrustEvidenceScope{instance_module: instance_module} = scope
       ) do
    TrustEvidenceScope.validate(scope)
  end

  defp validate_scope_instance(_instance_module, %TrustEvidenceScope{}),
    do: {:error, :trust_evidence_scope_instance_mismatch}

  defp validate_scope_instance(_instance_module, _scope),
    do: {:error, :trust_evidence_scope_required}

  defp validate_agent_subject(%Participant{type: :agent}), do: :ok
  defp validate_agent_subject(%Participant{}), do: {:error, :trust_evidence_subject_not_agent}

  defp validate_distinct_issuer(%Participant{id: id}, %Participant{id: id}),
    do: {:error, :self_issued_trust_evidence}

  defp validate_distinct_issuer(%Participant{}, %Participant{}), do: :ok

  defp validate_source(persistence, state, %TrustEvidence{source: %{kind: :message}} = evidence) do
    case persistence.get_message(state, evidence.source.id) do
      {:ok, %Message{room_id: room_id, sender_id: issuer_id}}
      when room_id == evidence.room_id and issuer_id == evidence.issuer_principal_id ->
        :ok

      {:ok, %Message{room_id: room_id}} when room_id != evidence.room_id ->
        {:error, :trust_evidence_source_room_violation}

      {:ok, %Message{}} ->
        {:error, :trust_evidence_source_issuer_violation}

      {:error, :not_found} ->
        {:error, :trust_evidence_source_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_source(_persistence, _state, %TrustEvidence{source: %{kind: :provider_record}}),
    do: :ok

  defp ensure_persistence(persistence) do
    if function_exported?(persistence, :save_trust_evidence, 2) do
      :ok
    else
      {:error, :trust_evidence_persistence_not_supported}
    end
  end

  defp list_persistence_supported?(persistence),
    do: function_exported?(persistence, :list_trust_evidence, 4)

  defp external_provider_id(provider) do
    provider
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.replace(~r/[^A-Za-z0-9._:-]/, "_")
  end
end
