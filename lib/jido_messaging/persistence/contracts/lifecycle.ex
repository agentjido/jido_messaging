defmodule Jido.Messaging.Persistence.Contracts.Lifecycle do
  @moduledoc """
  Storage contract for lifecycle.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  @type state :: Jido.Messaging.Persistence.state()
  @type capability :: Jido.Messaging.Persistence.capability()

  @callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}

  @callback capabilities(state) :: [capability]

  @callback health_check(state) :: :ok | {:error, term()}
end
