defmodule Jido.Messaging.Identity do
  @moduledoc false

  alias Jido.Chat.Participant

  alias Jido.Messaging.{
    Authorship,
    ExternalIdentityBinding,
    Message,
    Principal
  }

  @assurance_by_string %{
    "asserted" => :asserted,
    "provider_verified" => :provider_verified,
    "application_verified" => :application_verified,
    "cryptographically_verified" => :cryptographically_verified
  }

  @spec ensure_principal(module(), term(), Participant.t()) :: {:ok, Principal.t()} | {:error, term()}
  @doc false
  def ensure_principal(persistence, state, %Participant{} = participant) do
    principal = Principal.from_participant(participant)

    if identity_callback?(persistence, :get_principal, 2) do
      case persistence.get_principal(state, principal.id) do
        {:ok, %Principal{} = stored} -> {:ok, stored}
        {:error, :not_found} -> persist_or_project_principal(persistence, state, principal)
        {:error, _reason} = error -> error
      end
    else
      {:ok, principal}
    end
  end

  @spec persist_principal(module(), term(), Principal.t()) :: {:ok, Principal.t()} | {:error, term()}
  @doc false
  def persist_principal(persistence, state, %Principal{} = principal) do
    if identity_callback?(persistence, :save_principal, 2) do
      persistence.save_principal(state, principal)
    else
      {:error, :unsupported}
    end
  end

  @spec get_principal(module(), term(), String.t()) :: {:ok, Principal.t()} | {:error, term()}
  @doc false
  def get_principal(persistence, state, principal_id) do
    if identity_callback?(persistence, :get_principal, 2) do
      persistence.get_principal(state, principal_id)
    else
      {:error, :unsupported}
    end
  end

  @spec resolve_authorship(
          module(),
          term(),
          Participant.t(),
          atom() | String.t(),
          String.t(),
          String.t(),
          map(),
          keyword()
        ) :: {:ok, Principal.t(), ExternalIdentityBinding.t(), Authorship.t()} | {:error, term()}
  @doc false
  def resolve_authorship(
        persistence,
        state,
        %Participant{} = participant,
        channel,
        bridge_id,
        external_id,
        verify_result,
        opts \\ []
      ) do
    assurance = assurance_from_verify_result(verify_result)
    proof_ref = metadata_string(verify_result, :identity_proof_ref)

    runtime_execution_id =
      Keyword.get(opts, :runtime_execution_id) || metadata_string(verify_result, :runtime_execution_id)

    with {:ok, principal} <- ensure_principal(persistence, state, participant),
         :ok <- ensure_active_principal(principal),
         candidate <-
           ExternalIdentityBinding.new(%{
             principal_id: principal.id,
             participant_id: participant.id,
             channel: channel,
             bridge_id: bridge_id,
             external_id: external_id,
             assurance: assurance,
             proof_ref: proof_ref,
             verified_at: verified_at(assurance)
           }),
         {:ok, binding} <- ensure_binding(persistence, state, candidate),
         :ok <- ensure_active(binding),
         {:ok, principal} <- promote_principal_verification(persistence, state, principal, assurance) do
      authorship =
        build_authorship(
          persistence,
          participant.id,
          binding,
          assurance,
          proof_ref,
          runtime_execution_id
        )

      {:ok, principal, binding, authorship}
    end
  end

  @spec bind_external_identity(
          module(),
          term(),
          Principal.t(),
          atom() | String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, ExternalIdentityBinding.t()} | {:error, term()}
  @doc false
  def bind_external_identity(
        persistence,
        state,
        %Principal{} = principal,
        channel,
        bridge_id,
        external_id,
        opts \\ []
      ) do
    with true <- binding_persistence_supported?(persistence) || {:error, :unsupported},
         :ok <- ensure_active_principal(principal),
         {:ok, assurance} <- parse_assurance(Keyword.get(opts, :assurance, :asserted)) do
      candidate =
        ExternalIdentityBinding.new(%{
          principal_id: principal.id,
          participant_id: principal.participant_id,
          channel: channel,
          bridge_id: bridge_id,
          external_id: external_id,
          assurance: assurance,
          proof_ref: normalize_optional_string(Keyword.get(opts, :proof_ref)),
          verified_at: verified_at(assurance),
          metadata: Keyword.get(opts, :metadata, %{})
        })

      with {:ok, binding} <- ensure_binding(persistence, state, candidate),
           {:ok, _principal} <- promote_principal_verification(persistence, state, principal, assurance) do
        {:ok, binding}
      end
    end
  end

  @spec get_binding(module(), term(), String.t()) ::
          {:ok, ExternalIdentityBinding.t()} | {:error, term()}
  @doc false
  def get_binding(persistence, state, binding_id) do
    if identity_callback?(persistence, :get_external_identity_binding, 2) do
      persistence.get_external_identity_binding(state, binding_id)
    else
      {:error, :unsupported}
    end
  end

  @spec get_binding(module(), term(), atom() | String.t(), String.t(), String.t()) ::
          {:ok, ExternalIdentityBinding.t()} | {:error, term()}
  @doc false
  def get_binding(persistence, state, channel, bridge_id, external_id) do
    if identity_callback?(persistence, :get_external_identity_binding, 4) do
      persistence.get_external_identity_binding(state, channel, bridge_id, external_id)
    else
      {:error, :unsupported}
    end
  end

  @spec list_bindings(module(), term(), String.t(), keyword()) ::
          {:ok, [ExternalIdentityBinding.t()]} | {:error, term()}
  @doc false
  def list_bindings(persistence, state, principal_id, opts \\ []) do
    if identity_callback?(persistence, :list_external_identity_bindings, 3) do
      persistence.list_external_identity_bindings(state, principal_id, opts)
    else
      {:error, :unsupported}
    end
  end

  @spec save_binding(module(), term(), ExternalIdentityBinding.t()) ::
          {:ok, ExternalIdentityBinding.t()} | {:error, term()}
  @doc false
  def save_binding(persistence, state, %ExternalIdentityBinding{} = binding) do
    if identity_callback?(persistence, :save_external_identity_binding, 2) do
      persistence.save_external_identity_binding(state, binding)
    else
      {:error, :unsupported}
    end
  end

  @spec authorship_for_message(Message.t(), Participant.t()) :: Authorship.t()
  @doc false
  def authorship_for_message(%Message{} = message, %Participant{} = participant) do
    message.metadata
    |> metadata_value(:authorship)
    |> Authorship.from_map()
    |> case do
      {:ok, %Authorship{participant_id: participant_id} = authorship}
      when participant_id == participant.id and authorship.principal_id == participant.id ->
        authorship

      _other ->
        Authorship.asserted(participant.id, message.inserted_at || message.updated_at)
    end
  end

  @spec binding_for_message(module(), term(), Message.t(), Authorship.t()) ::
          ExternalIdentityBinding.t() | :ambiguous | nil
  @doc false
  def binding_for_message(persistence, state, %Message{} = message, %Authorship{} = authorship) do
    case authorship.external_identity_binding_id do
      nil ->
        binding_by_message_scope(persistence, state, message, authorship.principal_id)

      binding_id ->
        case binding_by_authorship_id(persistence, state, binding_id) do
          {:ok, binding} ->
            if binding_matches_message?(binding, message, authorship), do: binding, else: :ambiguous

          {:error, :unsupported} ->
            binding_by_message_scope(persistence, state, message, authorship.principal_id)

          _other ->
            :ambiguous
        end
    end
  end

  @spec put_authorship(Message.t(), Authorship.t()) :: Message.t()
  @doc false
  def put_authorship(%Message{} = message, %Authorship{} = authorship) do
    metadata = Map.put(message.metadata || %{}, :authorship, Authorship.to_map(authorship))
    %{message | metadata: metadata}
  end

  defp persist_or_project_principal(persistence, state, principal) do
    if identity_callback?(persistence, :save_principal, 2) do
      persistence.save_principal(state, principal)
    else
      {:ok, principal}
    end
  end

  defp ensure_binding(persistence, state, candidate) do
    if binding_persistence_supported?(persistence) do
      case persistence.get_external_identity_binding(
             state,
             candidate.channel,
             candidate.bridge_id,
             candidate.external_id
           ) do
        {:ok, %ExternalIdentityBinding{} = existing} ->
          cond do
            existing.principal_id != candidate.principal_id ->
              {:error, {:external_identity_conflict, existing.principal_id}}

            existing.participant_id != candidate.participant_id ->
              {:error, {:external_identity_conflict, existing.participant_id}}

            existing.status == :revoked ->
              {:error, :external_identity_revoked}

            true ->
              strengthened = ExternalIdentityBinding.strengthen(existing, candidate)

              if strengthened == existing do
                {:ok, existing}
              else
                persistence.save_external_identity_binding(state, strengthened)
              end
          end

        {:error, :not_found} ->
          persistence.save_external_identity_binding(state, candidate)

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, candidate}
    end
  end

  defp build_authorship(persistence, participant_id, binding, assurance, proof_ref, runtime_execution_id) do
    if binding_persistence_supported?(persistence) do
      Authorship.from_binding(participant_id, binding,
        assurance: assurance,
        proof_ref: proof_ref,
        runtime_execution_id: normalize_optional_string(runtime_execution_id)
      )
    else
      Authorship.new(%{
        principal_id: binding.principal_id,
        participant_id: participant_id,
        assurance: assurance,
        proof_ref: proof_ref,
        runtime_execution_id: normalize_optional_string(runtime_execution_id)
      })
    end
  end

  defp binding_by_authorship_id(persistence, state, binding_id),
    do: get_binding(persistence, state, binding_id)

  defp binding_by_message_scope(persistence, state, message, principal_id) do
    channel = metadata_value(message.metadata, :channel)
    bridge_id = metadata_value(message.metadata, :bridge_id)

    with channel when not is_nil(channel) <- channel,
         bridge_id when not is_nil(bridge_id) <- bridge_id,
         {:ok, bindings} <- list_bindings(persistence, state, principal_id, limit: 100) do
      bindings
      |> Enum.filter(fn binding ->
        binding.channel == to_string(channel) and binding.bridge_id == to_string(bridge_id)
      end)
      |> case do
        [binding] -> binding
        [] -> nil
        _multiple -> :ambiguous
      end
    else
      _other -> nil
    end
  end

  defp binding_matches_message?(binding, message, authorship) do
    channel = metadata_value(message.metadata, :channel)
    bridge_id = metadata_value(message.metadata, :bridge_id)

    binding.principal_id == authorship.principal_id and
      binding.participant_id == authorship.participant_id and
      (is_nil(channel) or binding.channel == to_string(channel)) and
      (is_nil(bridge_id) or binding.bridge_id == to_string(bridge_id))
  end

  defp assurance_from_verify_result(verify_result) do
    assurance =
      verify_result
      |> metadata_value(:metadata)
      |> metadata_value(:identity_assurance)

    case parse_assurance(assurance) do
      {:ok, parsed} -> parsed
      {:error, :invalid_identity_assurance} -> :asserted
    end
  end

  defp parse_assurance(assurance)
       when assurance in [
              :asserted,
              :provider_verified,
              :application_verified,
              :cryptographically_verified
            ],
       do: {:ok, assurance}

  defp parse_assurance(assurance) when is_binary(assurance) do
    normalized = assurance |> String.trim() |> String.downcase()

    case Map.fetch(@assurance_by_string, normalized) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :invalid_identity_assurance}
    end
  end

  defp parse_assurance(_assurance), do: {:error, :invalid_identity_assurance}

  defp metadata_string(verify_result, key) do
    verify_result
    |> metadata_value(:metadata)
    |> metadata_value(key)
    |> normalize_optional_string()
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      byte_size(value) > 512 -> String.slice(value, 0, 512)
      true -> value
    end
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp verified_at(:asserted), do: nil
  defp verified_at(_assurance), do: DateTime.utc_now()

  defp ensure_active(%ExternalIdentityBinding{status: :active}), do: :ok
  defp ensure_active(%ExternalIdentityBinding{status: :revoked}), do: {:error, :external_identity_revoked}

  defp ensure_active_principal(%Principal{status: :active, verification_state: :revoked}),
    do: {:error, :principal_verification_revoked}

  defp ensure_active_principal(%Principal{status: :active}), do: :ok

  defp ensure_active_principal(%Principal{status: status}), do: {:error, {:principal_inactive, status}}

  defp promote_principal_verification(_persistence, _state, principal, :asserted),
    do: {:ok, principal}

  defp promote_principal_verification(
         persistence,
         state,
         %Principal{verification_state: :unverified} = principal,
         _assurance
       ) do
    verified = %{principal | verification_state: :verified, updated_at: DateTime.utc_now()}

    case persist_principal(persistence, state, verified) do
      {:ok, stored} -> {:ok, stored}
      {:error, :unsupported} -> {:ok, verified}
      {:error, _reason} = error -> error
    end
  end

  defp promote_principal_verification(_persistence, _state, principal, _assurance),
    do: {:ok, principal}

  defp identity_callback?(persistence, name, arity), do: function_exported?(persistence, name, arity)

  defp binding_persistence_supported?(persistence) do
    identity_callback?(persistence, :save_principal, 2) and
      identity_callback?(persistence, :get_principal, 2) and
      identity_callback?(persistence, :save_external_identity_binding, 2) and
      identity_callback?(persistence, :get_external_identity_binding, 2) and
      identity_callback?(persistence, :get_external_identity_binding, 4) and
      identity_callback?(persistence, :list_external_identity_bindings, 3)
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  defp metadata_value(_metadata, _key), do: nil
end
