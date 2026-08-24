defmodule Jido.Messaging.IdentityEvidence do
  @moduledoc """
  Ephemeral identity assurance that keeps authorship and controller proof apart.

  Evidence is not an authorization result or reusable capability. Credentialed
  evidence can be added to message metadata only when the message author is the
  credential subject.
  """

  alias Jido.Messaging.Message

  @enforce_keys [
    :assurance,
    :subject_principal_id,
    :audience,
    :room_id,
    :verified_at,
    :valid_until
  ]
  defstruct [
    :assurance,
    :subject_principal_id,
    :controller_principal_id,
    :purpose,
    :credential_id,
    :credential_revision,
    :provider_id,
    :proof_type,
    :key_version_ref,
    :verification_ref,
    :audience,
    :room_id,
    :verified_at,
    :valid_until,
    provider_metadata: %{}
  ]

  @type assurance :: :uncredentialed | :attested | :verified
  @type t :: %__MODULE__{
          assurance: assurance(),
          subject_principal_id: String.t(),
          controller_principal_id: String.t() | nil,
          purpose: Jido.Messaging.IdentityCredential.purpose() | nil,
          credential_id: String.t() | nil,
          credential_revision: pos_integer() | nil,
          provider_id: String.t() | nil,
          proof_type: String.t() | nil,
          key_version_ref: String.t() | nil,
          verification_ref: String.t() | nil,
          audience: String.t(),
          room_id: String.t(),
          verified_at: DateTime.t(),
          valid_until: DateTime.t(),
          provider_metadata: map()
        }

  @doc "Creates lower-assurance evidence for an optional uncredentialed agent."
  @spec uncredentialed(String.t(), String.t(), String.t(), keyword()) :: t()
  def uncredentialed(subject_principal_id, audience, room_id, opts \\ []) do
    verified_at = DateTime.utc_now()

    valid_for_ms =
      opts
      |> Keyword.get(:evidence_valid_for_ms, Keyword.get(opts, :valid_for_ms, 60_000))
      |> bounded_validity()

    %__MODULE__{
      assurance: :uncredentialed,
      subject_principal_id: to_string(subject_principal_id),
      audience: to_string(audience),
      room_id: to_string(room_id),
      verified_at: verified_at,
      valid_until: DateTime.add(verified_at, valid_for_ms, :millisecond)
    }
  end

  @doc "Adds separate controller evidence without changing message authorship."
  @spec annotate_message(Message.t(), t()) :: {:ok, Message.t()} | {:error, atom()}
  def annotate_message(%Message{} = message, %__MODULE__{} = evidence) do
    cond do
      not current?(evidence) ->
        {:error, :identity_evidence_expired}

      message.sender_id != evidence.subject_principal_id ->
        {:error, :identity_evidence_subject_mismatch}

      message.room_id != evidence.room_id ->
        {:error, :identity_evidence_room_mismatch}

      true ->
        metadata = Map.put(message.metadata || %{}, :identity_evidence, to_map(evidence))
        {:ok, %{message | metadata: metadata}}
    end
  end

  @doc "Tests whether ephemeral evidence is current at a point in time."
  @spec current?(t(), DateTime.t()) :: boolean()
  def current?(%__MODULE__{} = evidence, at \\ DateTime.utc_now()) do
    DateTime.compare(at, evidence.verified_at) != :lt and
      DateTime.compare(at, evidence.valid_until) == :lt
  end

  @doc "Converts evidence to safe messaging metadata or Jidoka integration context."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = evidence) do
    %{
      assurance: evidence.assurance,
      authored_by_principal_id: evidence.subject_principal_id,
      controller_principal_id: evidence.controller_principal_id,
      purpose: evidence.purpose,
      credential: revision_ref(evidence.credential_id, evidence.credential_revision),
      provider_id: evidence.provider_id,
      proof_type: evidence.proof_type,
      key_version_ref: evidence.key_version_ref,
      verification_ref: evidence.verification_ref,
      audience: evidence.audience,
      room_id: evidence.room_id,
      provider_metadata: evidence.provider_metadata,
      verified_at: evidence.verified_at,
      valid_until: evidence.valid_until
    }
  end

  defp revision_ref(nil, nil), do: nil
  defp revision_ref(id, revision), do: %{id: id, revision: revision}

  defp bounded_validity(value) when is_integer(value), do: value |> max(1) |> min(300_000)
  defp bounded_validity(_value), do: 60_000
end
