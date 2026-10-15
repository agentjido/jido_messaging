defmodule Jido.Messaging.Persistence.Contracts.ExternalIdentity do
  @moduledoc """
  Storage contract for external identity.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.ExternalIdentityBinding

  @type state :: Jido.Messaging.Persistence.state()
  @type channel :: Jido.Messaging.Persistence.channel()
  @type bridge_id :: Jido.Messaging.Persistence.bridge_id()
  @type external_id :: Jido.Messaging.Persistence.external_id()

  @callback save_external_identity_binding(state, ExternalIdentityBinding.t()) ::
              {:ok, ExternalIdentityBinding.t()}
              | {:error, :not_found | :external_identity_revoked | {:external_identity_conflict, String.t()}}

  @callback get_external_identity_binding(state, String.t()) ::
              {:ok, ExternalIdentityBinding.t()} | {:error, :not_found}

  @callback get_external_identity_binding(state, channel, bridge_id, external_id) ::
              {:ok, ExternalIdentityBinding.t()} | {:error, :not_found}

  @callback list_external_identity_bindings(state, String.t(), keyword()) ::
              {:ok, [ExternalIdentityBinding.t()]} | {:error, term()}
end
