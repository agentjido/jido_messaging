defmodule Jido.Messaging.IdentityCredentials do
  @moduledoc false

  alias Jido.Messaging.{IdentityCredential, IdentityData, Runtime}

  @doc false
  @spec create(atom(), map()) :: {:ok, IdentityCredential.t()} | {:error, term()}
  def create(runtime, attrs) when is_atom(runtime) and is_map(attrs) do
    credential = IdentityCredential.new(attrs)
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, save_identity_credential: 2),
         :ok <- validate_initial(credential),
         :ok <- validate_participants(persistence, state, credential),
         :ok <- validate_rooms(persistence, state, credential.conditions.room_ids) do
      persistence.save_identity_credential(state, credential)
    end
  rescue
    ArgumentError -> {:error, :invalid_identity_credential}
  end

  @doc false
  @spec get(atom(), String.t()) :: {:ok, IdentityCredential.t()} | {:error, term()}
  def get(runtime, credential_id) when is_atom(runtime) and is_binary(credential_id) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, get_identity_credential: 2) do
      persistence.get_identity_credential(state, credential_id)
    end
  end

  @doc false
  @spec list(atom(), String.t(), keyword()) :: {:ok, [IdentityCredential.t()]} | {:error, term()}
  def list(runtime, subject_principal_id, opts \\ [])
      when is_atom(runtime) and is_binary(subject_principal_id) and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, list_identity_credentials: 3) do
      persistence.list_identity_credentials(state, subject_principal_id, opts)
    end
  end

  @doc false
  @spec transition(atom(), String.t(), pos_integer(), IdentityCredential.status(), keyword()) ::
          {:ok, IdentityCredential.t()} | {:error, term()}
  def transition(runtime, credential_id, expected_revision, status, opts \\ [])
      when is_atom(runtime) and is_binary(credential_id) and is_integer(expected_revision) and
             status in [:active, :suspended, :revoked] and is_list(opts) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <- require_callbacks(persistence, get_identity_credential: 2, save_identity_credential: 2),
         {:ok, credential} <- persistence.get_identity_credential(state, credential_id),
         :ok <- expected_revision(credential, expected_revision),
         {:ok, revised} <- transition_record(credential, status, opts) do
      persistence.save_identity_credential(state, revised)
    end
  end

  @doc false
  @spec rotate(atom(), String.t(), pos_integer(), map()) ::
          {:ok, %{revoked: IdentityCredential.t(), credential: IdentityCredential.t()}}
          | {:error, term()}
  def rotate(runtime, credential_id, expected_revision, attrs)
      when is_atom(runtime) and is_binary(credential_id) and is_integer(expected_revision) and
             is_map(attrs) do
    {persistence, state} = Runtime.get_persistence(runtime)

    with :ok <-
           require_callbacks(persistence,
             get_identity_credential: 2,
             rotate_identity_credential: 3
           ),
         {:ok, credential} <- persistence.get_identity_credential(state, credential_id),
         :ok <- expected_revision(credential, expected_revision),
         :ok <- rotatable(credential),
         {:ok, replacement} <- replacement_credential(credential, attrs),
         :ok <- validate_rooms(persistence, state, replacement.conditions.room_ids),
         revoked = IdentityCredential.transition(credential, :revoked, reason: "rotated"),
         {:ok, revoked, replacement} <-
           persistence.rotate_identity_credential(state, revoked, replacement) do
      {:ok, %{revoked: revoked, credential: replacement}}
    end
  rescue
    ArgumentError -> {:error, :invalid_identity_credential_rotation}
  end

  defp validate_initial(%IdentityCredential{} = credential) do
    cond do
      credential.revision != 1 ->
        {:error, {:invalid_initial_revision, credential.revision}}

      credential.status != :active ->
        {:error, {:invalid_initial_status, credential.status}}

      DateTime.compare(DateTime.utc_now(), credential.expires_at) != :lt ->
        {:error, :identity_credential_expired}

      true ->
        :ok
    end
  end

  defp validate_participants(persistence, state, credential) do
    with {:ok, _issuer} <- persistence.get_participant(state, credential.issuer_principal_id),
         {:ok, _subject} <- persistence.get_participant(state, credential.subject_principal_id) do
      :ok
    end
  end

  defp validate_rooms(persistence, state, room_ids) do
    Enum.reduce_while(room_ids, :ok, fn room_id, :ok ->
      case persistence.get_room(state, room_id) do
        {:ok, _room} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp expected_revision(%IdentityCredential{revision: revision}, revision), do: :ok

  defp expected_revision(%IdentityCredential{revision: revision}, _expected),
    do: {:error, {:stale_revision, revision}}

  defp transition_record(credential, status, opts) do
    changed_at = Keyword.get(opts, :changed_at, DateTime.utc_now())

    cond do
      not match?(%DateTime{}, changed_at) ->
        {:error, :invalid_identity_credential_transition}

      credential.status == :revoked ->
        {:error, :identity_credential_revocation_terminal}

      status == :active and DateTime.compare(changed_at, credential.expires_at) != :lt ->
        {:error, :identity_credential_expired}

      true ->
        {:ok, IdentityCredential.transition(credential, status, opts)}
    end
  rescue
    ArgumentError -> {:error, :invalid_identity_credential_transition}
  end

  defp rotatable(%IdentityCredential{status: :revoked}),
    do: {:error, :identity_credential_revocation_terminal}

  defp rotatable(%IdentityCredential{status: :suspended}),
    do: {:error, :identity_credential_inactive}

  defp rotatable(%IdentityCredential{} = credential) do
    if DateTime.compare(DateTime.utc_now(), credential.expires_at) == :lt,
      do: :ok,
      else: {:error, :identity_credential_expired}
  end

  defp replacement_credential(credential, attrs) do
    :ok = reject_rotation_identity_changes!(credential, attrs)

    replacement_attrs =
      attrs
      |> Map.put(:issuer_principal_id, credential.issuer_principal_id)
      |> Map.put(:subject_principal_id, credential.subject_principal_id)
      |> Map.put(:purpose, credential.purpose)
      |> Map.put(:conditions, credential.conditions)
      |> Map.put(:rotated_from_credential_id, credential.id)
      |> Map.put(:status, :active)
      |> Map.put(:revision, 1)

    {:ok, IdentityCredential.new(replacement_attrs)}
  end

  defp reject_rotation_identity_changes!(credential, attrs) do
    immutable = [
      {:issuer_principal_id, credential.issuer_principal_id},
      {:subject_principal_id, credential.subject_principal_id},
      {:purpose, credential.purpose}
    ]

    Enum.each(immutable, fn {key, current} ->
      case IdentityData.value(attrs, key) do
        nil -> :ok
        ^current -> :ok
        value when key == :purpose and value == "controller" -> :ok
        _other -> raise ArgumentError, "identity credential rotation cannot change #{key}"
      end
    end)

    case IdentityData.value(attrs, :conditions) do
      nil ->
        :ok

      conditions ->
        if Jido.Messaging.IdentityCredentialConditions.new(conditions) != credential.conditions do
          raise ArgumentError, "identity credential rotation cannot change conditions"
        end
    end

    :ok
  end

  defp require_callbacks(persistence, callbacks) do
    if Enum.all?(callbacks, fn {name, arity} -> function_exported?(persistence, name, arity) end),
      do: :ok,
      else: {:error, :unsupported}
  end
end
