defmodule Jido.Messaging.IdentityVerifier do
  @moduledoc """
  Bounded verification for optional controller credentials.

  Core checks current lifecycle, audience, room, subject, proof references,
  assertion age, and replay. An optional provider owns cryptographic or remote
  proof verification. Successful evidence does not grant a messaging action.
  """

  alias Jido.Messaging.{
    IdentityCredential,
    IdentityData,
    IdentityEvidence,
    Runtime
  }

  @default_timeout 5_000
  @max_timeout 30_000
  @default_assertion_age_ms 300_000
  @max_assertion_age_ms 3_600_000
  @default_clock_skew_ms 30_000
  @max_clock_skew_ms 300_000
  @default_evidence_validity_ms 60_000
  @max_evidence_validity_ms 300_000

  @doc "Verifies one controller proof and consumes its assertion ID once."
  @spec verify(atom(), String.t(), map(), map(), keyword()) ::
          {:ok, IdentityEvidence.t()} | {:error, term()}
  def verify(runtime, credential_id, proof, context, opts \\ [])
      when is_atom(runtime) and is_binary(credential_id) and is_map(proof) and is_map(context) and
             is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)
    now = DateTime.utc_now()

    with :ok <- require_callbacks(persistence),
         {:ok, credential} <- persistence.get_identity_credential(state, credential_id),
         :ok <- validate_current_records(persistence, state, credential, context, now),
         {:ok, assertion_id} <- validate_proof(credential, proof, now, opts),
         {:ok, provider} <- provider(opts),
         {:ok, provider_result} <- invoke_provider(provider, credential, proof, context, opts),
         {:ok, provider_result} <- validate_provider_result(credential, provider_result),
         assertion_key = assertion_key(credential.id, assertion_id),
         :ok <-
           persistence.consume_identity_assertion(
             state,
             credential.id,
             assertion_key,
             credential.expires_at
           ) do
      {:ok,
       build_evidence(
         credential,
         context,
         provider_result,
         assertion_key,
         now,
         opts
       )}
    end
  rescue
    ArgumentError -> {:error, :invalid_identity_verification_request}
  end

  @doc "Returns lower assurance when no credential is supplied, or verifies one when present."
  @spec verify_optional(atom(), String.t() | nil, map(), map(), keyword()) ::
          {:ok, IdentityEvidence.t()} | {:error, term()}
  def verify_optional(runtime, credential_id, proof, context, opts \\ [])

  def verify_optional(runtime, nil, _proof, context, opts) do
    subject = context |> IdentityData.value(:subject_principal_id) |> IdentityData.required!(:subject_principal_id)
    audience = context |> IdentityData.value(:audience) |> IdentityData.required!(:audience)
    room_id = context |> IdentityData.value(:room_id) |> IdentityData.required!(:room_id)
    {persistence, state} = Runtime.get_persistence(runtime)

    with {:ok, _subject} <- persistence.get_participant(state, subject),
         {:ok, _room} <- persistence.get_room(state, room_id) do
      {:ok, IdentityEvidence.uncredentialed(subject, audience, room_id, opts)}
    end
  rescue
    ArgumentError -> {:error, :invalid_identity_verification_request}
  end

  def verify_optional(runtime, credential_id, proof, context, opts)
      when is_binary(credential_id),
      do: verify(runtime, credential_id, proof, context, opts)

  defp validate_current_records(persistence, state, credential, context, now) do
    subject = context |> IdentityData.value(:subject_principal_id) |> IdentityData.required!(:subject_principal_id)
    controller = IdentityData.value(context, :controller_principal_id)
    audience = context |> IdentityData.value(:audience) |> IdentityData.required!(:audience)
    room_id = context |> IdentityData.value(:room_id) |> IdentityData.required!(:room_id)

    cond do
      not IdentityCredential.active_at?(credential, now) ->
        {:error, :identity_credential_inactive}

      credential.subject_principal_id != subject ->
        {:error, :identity_credential_subject_mismatch}

      controller != nil and credential.issuer_principal_id != controller ->
        {:error, :identity_credential_controller_mismatch}

      credential.conditions.audience != audience ->
        {:error, :identity_credential_audience_mismatch}

      room_id not in credential.conditions.room_ids ->
        {:error, :identity_credential_room_mismatch}

      true ->
        with {:ok, _subject} <- persistence.get_participant(state, credential.subject_principal_id),
             {:ok, _issuer} <- persistence.get_participant(state, credential.issuer_principal_id),
             {:ok, _room} <- persistence.get_room(state, room_id) do
          :ok
        end
    end
  end

  defp validate_proof(credential, proof, now, opts) do
    assertion_id = proof |> IdentityData.value(:assertion_id) |> IdentityData.required!(:assertion_id)
    proof_type = proof |> IdentityData.value(:proof_type) |> IdentityData.required!(:proof_type)
    proof_ref = proof |> IdentityData.value(:proof_ref) |> IdentityData.required!(:proof_ref)
    issued_at = IdentityData.value(proof, :issued_at)
    max_age = bounded_option(opts, :max_assertion_age_ms, @default_assertion_age_ms, @max_assertion_age_ms)
    skew = bounded_option(opts, :clock_skew_ms, @default_clock_skew_ms, @max_clock_skew_ms)

    cond do
      not match?(%DateTime{}, issued_at) -> {:error, :identity_assertion_timestamp_required}
      proof_type != credential.proof_type -> {:error, :identity_proof_type_mismatch}
      proof_ref != credential.proof_ref -> {:error, :identity_proof_reference_mismatch}
      DateTime.compare(issued_at, credential.not_before) == :lt -> {:error, :identity_assertion_outside_validity}
      DateTime.compare(issued_at, credential.expires_at) != :lt -> {:error, :identity_assertion_outside_validity}
      DateTime.diff(issued_at, now, :millisecond) > skew -> {:error, :identity_assertion_from_future}
      DateTime.diff(now, issued_at, :millisecond) > max_age -> {:error, :identity_assertion_too_old}
      true -> {:ok, assertion_id}
    end
  end

  defp provider(opts) do
    case Keyword.get(opts, :provider) do
      provider when is_atom(provider) and provider != nil ->
        if Code.ensure_loaded?(provider) and function_exported?(provider, :verify, 4),
          do: {:ok, provider},
          else: {:error, :identity_provider_unavailable}

      _provider ->
        {:error, :identity_provider_unavailable}
    end
  end

  defp invoke_provider(provider, credential, proof, context, opts) do
    timeout = bounded_option(opts, :timeout, @default_timeout, @max_timeout)

    provider_opts =
      Keyword.drop(opts, [
        :provider,
        :timeout,
        :max_assertion_age_ms,
        :clock_skew_ms,
        :evidence_valid_for_ms,
        :valid_for_ms,
        :verified_at
      ])

    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_provider_call(provider, credential, proof, context, provider_opts)
        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_provider_result(result)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, {:identity_provider_failed, failure_class(reason)}}
    after
      timeout ->
        Process.exit(pid, :kill)
        await_down(monitor_ref, pid)
        flush_result(result_ref)
        {:error, :identity_provider_timeout}
    end
  end

  defp safe_provider_call(provider, credential, proof, context, opts) do
    provider.verify(credential, proof, context, opts)
  rescue
    exception -> {:error, {:provider_exception, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:provider_failure, kind}}
  end

  defp normalize_provider_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_provider_result({:error, _reason} = error), do: error
  defp normalize_provider_result(_result), do: {:error, :invalid_identity_provider_response}

  defp validate_provider_result(credential, result) do
    assurance = IdentityData.value(result, :assurance)
    key_version = IdentityData.value(result, :key_version_ref)
    metadata = result |> IdentityData.value(:metadata, %{}) |> IdentityData.metadata!()

    cond do
      assurance not in [:attested, :verified] ->
        {:error, :invalid_identity_assurance}

      credential.key_version_ref != nil and key_version != credential.key_version_ref ->
        {:error, :identity_key_version_mismatch}

      true ->
        {:ok, Map.merge(result, %{assurance: assurance, key_version_ref: key_version, metadata: metadata})}
    end
  end

  defp build_evidence(credential, context, provider_result, assertion_key, verified_at, opts) do
    evidence_validity =
      bounded_option(
        opts,
        :evidence_valid_for_ms,
        @default_evidence_validity_ms,
        @max_evidence_validity_ms
      )

    valid_until = earlier_datetime(credential.expires_at, DateTime.add(verified_at, evidence_validity, :millisecond))

    %IdentityEvidence{
      assurance: provider_result.assurance,
      subject_principal_id: credential.subject_principal_id,
      controller_principal_id: credential.issuer_principal_id,
      purpose: credential.purpose,
      credential_id: credential.id,
      credential_revision: credential.revision,
      provider_id: credential.provider_id,
      proof_type: credential.proof_type,
      key_version_ref: provider_result.key_version_ref || credential.key_version_ref,
      verification_ref: "identity_verification:#{assertion_key}",
      audience: IdentityData.value(context, :audience),
      room_id: IdentityData.value(context, :room_id),
      provider_metadata: provider_result.metadata,
      verified_at: verified_at,
      valid_until: valid_until
    }
  end

  defp assertion_key(credential_id, assertion_id) do
    :crypto.hash(:sha256, "v1:#{credential_id}:#{assertion_id}")
    |> Base.url_encode64(padding: false)
  end

  defp bounded_option(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) -> value |> max(1) |> min(maximum)
      _value -> default
    end
  end

  defp earlier_datetime(%DateTime{} = first, %DateTime{} = second) do
    if DateTime.compare(first, second) == :gt, do: second, else: first
  end

  defp await_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      100 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp flush_result(result_ref) do
    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp failure_class(:normal), do: :normal_exit
  defp failure_class(:killed), do: :killed
  defp failure_class(_reason), do: :provider_exit

  defp require_callbacks(persistence) do
    callbacks = [get_identity_credential: 2, consume_identity_assertion: 4]

    if Enum.all?(callbacks, fn {name, arity} -> function_exported?(persistence, name, arity) end),
      do: :ok,
      else: {:error, :unsupported}
  end
end
