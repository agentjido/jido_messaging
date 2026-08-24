defmodule Jido.Messaging.IdentityCredential do
  @moduledoc """
  Revisioned controller credential for one messaging principal.

  The record stores opaque provider and proof references. It never stores a
  raw proof, private key, public key, token, function, or environment data.
  A credential is identity evidence. It is not a messaging action grant.
  """

  alias Jido.Messaging.{IdentityCredentialConditions, IdentityData}

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              issuer_principal_id: Zoi.string(),
              subject_principal_id: Zoi.string(),
              purpose: Zoi.enum([:controller]),
              conditions: Zoi.struct(IdentityCredentialConditions),
              provider_id: Zoi.string(),
              proof_type: Zoi.string(),
              proof_ref: Zoi.string(),
              key_version_ref: Zoi.string() |> Zoi.nullish(),
              rotated_from_credential_id: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              revision: Zoi.integer() |> Zoi.default(1),
              issued_at: Zoi.struct(DateTime),
              not_before: Zoi.struct(DateTime),
              expires_at: Zoi.struct(DateTime),
              revoked_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              revocation_reason: Zoi.string() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type status :: :active | :suspended | :revoked
  @type purpose :: :controller
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for IdentityCredential."
  def schema, do: @schema

  @doc "Creates a bounded controller credential with explicit validity."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    :ok = IdentityData.reject_raw_identity_material!(attrs)
    now = DateTime.utc_now()
    issued_at = IdentityData.value(attrs, :issued_at, now)
    not_before = IdentityData.value(attrs, :not_before, issued_at)
    expires_at = IdentityData.value(attrs, :expires_at)
    revision = IdentityData.value(attrs, :revision, 1)
    id = attrs |> IdentityData.value(:id) |> IdentityData.optional!(:id) || Jido.Chat.ID.generate!()

    issuer_principal_id =
      attrs |> IdentityData.value(:issuer_principal_id) |> IdentityData.required!(:issuer_principal_id)

    subject_principal_id =
      attrs |> IdentityData.value(:subject_principal_id) |> IdentityData.required!(:subject_principal_id)

    status = attrs |> IdentityData.value(:status, :active) |> normalize_status!()
    revoked_at = IdentityData.value(attrs, :revoked_at)

    revocation_reason =
      attrs |> IdentityData.value(:revocation_reason) |> IdentityData.optional!(:revocation_reason)

    validate_revision!(revision)
    validate_validity!(issued_at, not_before, expires_at)
    validate_principal_relation!(issuer_principal_id, subject_principal_id)
    validate_lifecycle!(status, revoked_at, revocation_reason)

    attrs
    |> Map.put(:id, id)
    |> Map.put(:issuer_principal_id, issuer_principal_id)
    |> Map.put(:subject_principal_id, subject_principal_id)
    |> Map.put(:purpose, normalize_purpose!(IdentityData.value(attrs, :purpose, :controller)))
    |> Map.put(
      :conditions,
      attrs |> IdentityData.value(:conditions) |> IdentityCredentialConditions.new()
    )
    |> Map.put(:provider_id, attrs |> IdentityData.value(:provider_id) |> IdentityData.required!(:provider_id))
    |> Map.put(:proof_type, attrs |> IdentityData.value(:proof_type) |> IdentityData.required!(:proof_type))
    |> Map.put(:proof_ref, attrs |> IdentityData.value(:proof_ref) |> IdentityData.required!(:proof_ref))
    |> Map.put(
      :key_version_ref,
      attrs |> IdentityData.value(:key_version_ref) |> IdentityData.optional!(:key_version_ref)
    )
    |> Map.put(
      :rotated_from_credential_id,
      attrs
      |> IdentityData.value(:rotated_from_credential_id)
      |> IdentityData.optional!(:rotated_from_credential_id)
    )
    |> Map.put(:revision, revision)
    |> Map.put(:status, status)
    |> Map.put(:issued_at, issued_at)
    |> Map.put(:not_before, not_before)
    |> Map.put(:expires_at, expires_at)
    |> Map.put(:revoked_at, revoked_at)
    |> Map.put(:revocation_reason, revocation_reason)
    |> Map.put(:metadata, attrs |> IdentityData.value(:metadata, %{}) |> IdentityData.metadata!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Changes credential status and increments its revision."
  @spec transition(t(), status(), keyword()) :: t()
  def transition(%__MODULE__{} = credential, status, opts \\ [])
      when status in [:active, :suspended, :revoked] and is_list(opts) do
    changed_at = Keyword.get(opts, :changed_at, DateTime.utc_now())
    reason = Keyword.get(opts, :reason)

    if not match?(%DateTime{}, changed_at) do
      raise ArgumentError, "identity credential transition requires a DateTime"
    end

    if credential.status == :revoked do
      raise ArgumentError, "identity credential revocation is terminal"
    end

    if not valid_transition?(credential.status, status) do
      raise ArgumentError, "identity credential status transition is invalid"
    end

    %{
      credential
      | status: status,
        revision: credential.revision + 1,
        revoked_at: if(status == :revoked, do: changed_at, else: nil),
        revocation_reason: if(status == :revoked, do: IdentityData.optional!(reason, :revocation_reason), else: nil),
        updated_at: changed_at
    }
  end

  @doc "Tests whether the credential is active at a point in time."
  @spec active_at?(t(), DateTime.t()) :: boolean()
  def active_at?(%__MODULE__{} = credential, %DateTime{} = at) do
    credential.status == :active and DateTime.compare(at, credential.not_before) != :lt and
      DateTime.compare(at, credential.expires_at) == :lt
  end

  defp validate_revision!(revision) when is_integer(revision) and revision > 0, do: :ok
  defp validate_revision!(_revision), do: raise(ArgumentError, "credential revision must be a positive integer")

  defp validate_validity!(%DateTime{} = issued_at, %DateTime{} = not_before, %DateTime{} = expires_at) do
    if DateTime.compare(not_before, issued_at) == :lt or DateTime.compare(expires_at, not_before) != :gt do
      raise ArgumentError, "credential validity must satisfy issued_at <= not_before < expires_at"
    end
  end

  defp validate_validity!(_issued_at, _not_before, _expires_at),
    do: raise(ArgumentError, "credential validity requires DateTime values")

  defp validate_principal_relation!(principal_id, principal_id),
    do: raise(ArgumentError, "credential issuer and subject must be different principals")

  defp validate_principal_relation!(_issuer_principal_id, _subject_principal_id), do: :ok

  defp validate_lifecycle!(:revoked, %DateTime{}, _reason), do: :ok

  defp validate_lifecycle!(:revoked, _revoked_at, _reason),
    do: raise(ArgumentError, "revoked credential requires revoked_at")

  defp validate_lifecycle!(_status, nil, nil), do: :ok

  defp validate_lifecycle!(_status, _revoked_at, _reason),
    do: raise(ArgumentError, "active or suspended credential cannot have revocation data")

  defp normalize_purpose!(purpose) when purpose in [:controller], do: purpose
  defp normalize_purpose!("controller"), do: :controller
  defp normalize_purpose!(_purpose), do: raise(ArgumentError, "unsupported identity credential purpose")

  defp normalize_status!(status) when status in [:active, :suspended, :revoked], do: status
  defp normalize_status!("active"), do: :active
  defp normalize_status!("suspended"), do: :suspended
  defp normalize_status!("revoked"), do: :revoked
  defp normalize_status!(_status), do: raise(ArgumentError, "unsupported identity credential status")

  defp valid_transition?(:active, status) when status in [:suspended, :revoked], do: true
  defp valid_transition?(:suspended, status) when status in [:active, :revoked], do: true
  defp valid_transition?(_current, _next), do: false
end
