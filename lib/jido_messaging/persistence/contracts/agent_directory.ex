defmodule Jido.Messaging.Persistence.Contracts.AgentDirectory do
  @moduledoc """
  Storage contract for agent directory.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.AgentDirectoryProjection

  @type state :: Jido.Messaging.Persistence.state()

  @callback save_agent_directory_projection(state, AgentDirectoryProjection.t()) ::
              {:ok, AgentDirectoryProjection.t()} | {:error, term()}

  @callback get_agent_directory_projection(state, String.t()) ::
              {:ok, AgentDirectoryProjection.t()} | {:error, :not_found | term()}

  @callback list_agent_directory_projections(state, opts :: keyword()) ::
              {:ok, [AgentDirectoryProjection.t()]} | {:error, term()}
end
