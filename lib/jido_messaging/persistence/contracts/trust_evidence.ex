defmodule Jido.Messaging.Persistence.Contracts.TrustEvidence do
  @moduledoc """
  Storage contract for trust evidence.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.TrustEvidence

  @type state :: Jido.Messaging.Persistence.state()
  @type room_id :: Jido.Messaging.Persistence.room_id()
  @type participant_id :: Jido.Messaging.Persistence.participant_id()

  @callback save_trust_evidence(state, TrustEvidence.t()) ::
              {:ok, TrustEvidence.t()} | {:error, term()}

  @callback list_trust_evidence(state, participant_id(), room_id(), keyword()) ::
              {:ok, [TrustEvidence.t()]} | {:error, term()}
end
