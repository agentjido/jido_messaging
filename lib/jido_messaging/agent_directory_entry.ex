defmodule Jido.Messaging.AgentDirectoryEntry do
  @moduledoc """
  Time-effective discovery result for one Jidoka agent.

  `invokable` is a safe directory hint. It is not authorization. The caller
  must get a current invocation decision before it sends a request.
  """

  alias Jido.Messaging.AgentDirectoryProjection

  @enforce_keys [
    :id,
    :jidoka_agent_ref,
    :principal_id,
    :name,
    :capabilities,
    :availability,
    :version,
    :invocation_summary,
    :verification_state,
    :source_revision,
    :source_updated_at,
    :freshness,
    :invokable
  ]
  defstruct [
    :id,
    :jidoka_agent_ref,
    :principal_id,
    :endpoint_ref,
    :name,
    :description,
    :capabilities,
    :availability,
    :version,
    :invocation_summary,
    :verification_state,
    :source_revision,
    :source_updated_at,
    :freshness,
    :invokable
  ]

  @type freshness :: :fresh | :stale
  @type t :: %__MODULE__{
          id: String.t(),
          jidoka_agent_ref: map(),
          principal_id: String.t(),
          endpoint_ref: Jido.Messaging.AgentDirectoryEndpointRef.t() | nil,
          name: String.t(),
          description: String.t() | nil,
          capabilities: [String.t()],
          availability: AgentDirectoryProjection.availability(),
          version: String.t(),
          invocation_summary: Jido.Messaging.AgentInvocationSummary.t(),
          verification_state: AgentDirectoryProjection.verification_state(),
          source_revision: pos_integer(),
          source_updated_at: DateTime.t(),
          freshness: freshness(),
          invokable: boolean()
        }

  @doc "Builds a time-effective directory result."
  @spec new(AgentDirectoryProjection.t(), DateTime.t()) :: t()
  def new(%AgentDirectoryProjection{} = projection, now \\ DateTime.utc_now()) do
    freshness = if DateTime.compare(now, projection.fresh_until) == :lt, do: :fresh, else: :stale

    %__MODULE__{
      id: projection.id,
      jidoka_agent_ref: projection.jidoka_agent_ref,
      principal_id: projection.principal_id,
      endpoint_ref: projection.endpoint_ref,
      name: projection.name,
      description: projection.description,
      capabilities: projection.capabilities,
      availability: projection.availability,
      version: projection.version,
      invocation_summary: projection.invocation_summary,
      verification_state: projection.verification_state,
      source_revision: projection.source_revision,
      source_updated_at: projection.source_updated_at,
      freshness: freshness,
      invokable:
        projection.listing_state == :listed and projection.availability == :available and
          projection.verification_state != :rejected and not is_nil(projection.endpoint_ref) and
          freshness == :fresh
    }
  end
end
