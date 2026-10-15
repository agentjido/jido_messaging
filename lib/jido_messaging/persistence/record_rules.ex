defmodule Jido.Messaging.Persistence.RecordRules do
  @moduledoc false

  alias Jido.Messaging.{AgentDirectoryProjection, MessagingActivityEntry}

  @doc "Checks an authorization revision after the adapter has read the stored record."
  @spec authorization_revision(map() | nil, map(), (map(), map() -> boolean())) :: :ok | {:error, term()}
  def authorization_revision(nil, %{revision: 1}, _identity?), do: :ok

  def authorization_revision(nil, record, _identity?),
    do: {:error, {:invalid_initial_revision, record.revision}}

  def authorization_revision(stored, record, _identity?) when stored == record, do: :ok

  def authorization_revision(stored, record, identity?) do
    cond do
      not identity?.(stored, record) -> {:error, :authorization_identity_immutable}
      stored.status == :revoked and record.status != :revoked -> {:error, :authorization_revocation_terminal}
      record.revision == stored.revision + 1 -> :ok
      true -> {:error, {:stale_revision, stored.revision}}
    end
  end

  @doc "Checks immutable membership identity."
  @spec membership_identity?(map(), map()) :: boolean()
  def membership_identity?(stored, record) do
    stored.principal_id == record.principal_id and stored.room_id == record.room_id and
      stored.issuer_principal_id == record.issuer_principal_id
  end

  @doc "Checks immutable grant identity."
  @spec grant_identity?(stored :: map(), record :: map()) :: boolean()
  def grant_identity?(stored, record) do
    stored.principal_id == record.principal_id and stored.issuer_principal_id == record.issuer_principal_id
  end

  @doc "Checks immutable invocation-policy identity."
  @spec policy_identity?(map(), map()) :: boolean()
  def policy_identity?(stored, record) do
    stored.target_principal_id == record.target_principal_id and
      stored.issuer_principal_id == record.issuer_principal_id and stored.scope == record.scope
  end

  @doc "Checks credential revision and terminal revocation."
  @spec credential_revision(map() | nil, map()) :: :ok | {:error, term()}
  def credential_revision(nil, %{revision: 1, status: :active}), do: :ok

  def credential_revision(nil, %{revision: revision}) when revision != 1,
    do: {:error, {:invalid_initial_revision, revision}}

  def credential_revision(nil, credential), do: {:error, {:invalid_initial_status, credential.status}}
  def credential_revision(stored, credential) when stored == credential, do: :ok

  def credential_revision(stored, credential) do
    cond do
      not credential_identity?(stored, credential) -> {:error, :identity_credential_identity_immutable}
      stored.status == :revoked -> {:error, :identity_credential_revocation_terminal}
      credential.revision != stored.revision + 1 -> {:error, {:stale_revision, stored.revision}}
      true -> :ok
    end
  end

  @doc "Checks immutable credential fields."
  @spec credential_identity?(map(), map()) :: boolean()
  def credential_identity?(left, right) do
    left.id == right.id and credential_relation?(left, right) and
      left.provider_id == right.provider_id and left.proof_type == right.proof_type and
      left.proof_ref == right.proof_ref and left.key_version_ref == right.key_version_ref and
      left.rotated_from_credential_id == right.rotated_from_credential_id and
      left.issued_at == right.issued_at and left.not_before == right.not_before and
      left.expires_at == right.expires_at and left.inserted_at == right.inserted_at and
      left.metadata == right.metadata
  end

  @doc "Checks credential ownership and purpose across rotation."
  @spec credential_relation?(map(), map()) :: boolean()
  def credential_relation?(left, right) do
    left.issuer_principal_id == right.issuer_principal_id and
      left.subject_principal_id == right.subject_principal_id and
      left.purpose == right.purpose and left.conditions == right.conditions
  end

  @doc "Checks a directory revision and preserves its insertion time."
  @spec agent_directory_revision(AgentDirectoryProjection.t() | nil, AgentDirectoryProjection.t()) ::
          {:ok, AgentDirectoryProjection.t()} | {:store, AgentDirectoryProjection.t()} | {:error, term()}
  def agent_directory_revision(nil, %{source_revision: 1} = projection), do: {:store, projection}

  def agent_directory_revision(nil, projection),
    do: {:error, {:invalid_initial_revision, projection.source_revision}}

  def agent_directory_revision(stored, projection) do
    cond do
      AgentDirectoryProjection.equivalent?(stored, projection) ->
        {:ok, stored}

      not AgentDirectoryProjection.same_identity?(stored, projection) ->
        {:error, :agent_directory_identity_immutable}

      projection.source_revision == stored.source_revision ->
        {:error, :agent_directory_revision_conflict}

      projection.source_revision < stored.source_revision ->
        {:error, {:stale_revision, stored.source_revision}}

      projection.source_revision != stored.source_revision + 1 ->
        {:error, {:revision_gap, stored.source_revision, projection.source_revision}}

      true ->
        {:store, AgentDirectoryProjection.preserve_insertion(projection, stored)}
    end
  end

  @doc "Checks an activity revision and preserves its insertion time."
  @spec activity_revision(MessagingActivityEntry.t(), MessagingActivityEntry.t()) ::
          {:ok, MessagingActivityEntry.t()} | {:store, MessagingActivityEntry.t()} | {:error, term()}
  def activity_revision(stored, incoming) do
    cond do
      incoming.source_revision < stored.source_revision ->
        {:error, {:stale_activity_revision, stored.source_revision}}

      incoming.source_revision == stored.source_revision and MessagingActivityEntry.equivalent?(stored, incoming) ->
        {:ok, stored}

      incoming.source_revision == stored.source_revision ->
        {:error, :activity_projection_conflict}

      not MessagingActivityEntry.same_correlation?(stored, incoming) ->
        {:error, :activity_correlation_immutable}

      true ->
        {:store, MessagingActivityEntry.preserve_insertion(incoming, stored)}
    end
  end

  @doc "Checks message cursor options. Cursor lookup remains in the adapter."
  @spec cursor_direction(keyword()) :: {:ok, :none | {:before | :after, String.t()}} | {:error, :invalid_cursor_options}
  def cursor_direction(opts) do
    case {Keyword.get(opts, :before), Keyword.get(opts, :after)} do
      {nil, nil} -> {:ok, :none}
      {before, nil} when is_binary(before) and before != "" -> {:ok, {:before, before}}
      {nil, after_cursor} when is_binary(after_cursor) and after_cursor != "" -> {:ok, {:after, after_cursor}}
      {_before, _after_cursor} -> {:error, :invalid_cursor_options}
    end
  end

  @doc "Builds the seven existing SQL index values without changing the payload."
  @spec index_columns(keyword()) :: [term()]
  def index_columns(opts) do
    [
      Keyword.get(opts, :room_id),
      Keyword.get(opts, :thread_id),
      Keyword.get(opts, :sender_id),
      format_datetime(Keyword.get(opts, :inserted_at)),
      normalize_nullable(Keyword.get(opts, :channel)),
      normalize_nullable(Keyword.get(opts, :bridge_id)),
      normalize_nullable(Keyword.get(opts, :external_id))
    ]
  end

  @doc "Formats the existing timestamp index in UTC."
  @spec format_datetime(term()) :: String.t() | nil
  def format_datetime(nil), do: nil
  def format_datetime(%DateTime{} = value), do: Jido.Messaging.Transcript.format_timestamp(value)
  def format_datetime(value), do: to_string(value)

  @doc "Normalizes a nullable index value."
  @spec normalize_nullable(term()) :: String.t() | nil
  def normalize_nullable(nil), do: nil
  def normalize_nullable(value), do: normalize_term(value)

  @doc "Normalizes an existing provider index value."
  @spec normalize_term(term()) :: String.t()
  def normalize_term(value) when is_binary(value), do: value
  def normalize_term(value) when is_atom(value), do: Atom.to_string(value)
  def normalize_term(value) when is_integer(value), do: Integer.to_string(value)
  def normalize_term(value), do: inspect(value)
end
