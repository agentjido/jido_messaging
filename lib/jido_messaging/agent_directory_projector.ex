defmodule Jido.Messaging.AgentDirectoryProjector do
  @moduledoc """
  Contract for a Jidoka-owned adapter that builds safe directory input.

  The adapter can read Jidoka `Agent.Spec` data in its own integration layer.
  It must return only the fields accepted by
  `Jido.Messaging.AgentDirectoryProjection`. The source value and context are
  transient. Jido Messaging does not persist them.
  """

  @typedoc "Opaque Jidoka-owned source data."
  @type source :: term()

  @typedoc "Transient integration context."
  @type context :: map()

  @callback to_directory_projection(source(), context(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
