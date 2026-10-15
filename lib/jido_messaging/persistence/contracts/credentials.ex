defmodule Jido.Messaging.Persistence.Contracts.Credentials do
  @moduledoc """
  Storage contract for credentials.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.IdentityCredential

  @type state :: Jido.Messaging.Persistence.state()
  @type participant_id :: Jido.Messaging.Persistence.participant_id()

  @callback save_identity_credential(state, IdentityCredential.t()) ::
              {:ok, IdentityCredential.t()} | {:error, term()}

  @callback get_identity_credential(state, String.t()) ::
              {:ok, IdentityCredential.t()} | {:error, :not_found}

  @callback list_identity_credentials(state, participant_id(), keyword()) ::
              {:ok, [IdentityCredential.t()]} | {:error, term()}

  @callback rotate_identity_credential(
              state,
              revoked :: IdentityCredential.t(),
              replacement :: IdentityCredential.t()
            ) ::
              {:ok, IdentityCredential.t(), IdentityCredential.t()} | {:error, term()}

  @callback consume_identity_assertion(
              state,
              credential_id :: String.t(),
              assertion_key :: String.t(),
              expires_at :: DateTime.t()
            ) :: :ok | {:error, term()}
end
