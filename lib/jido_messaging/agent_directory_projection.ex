defmodule Jido.Messaging.AgentDirectoryProjection do
  @moduledoc """
  Safe searchable projection of one Jidoka agent for messaging discovery.

  Jidoka remains the source of the agent definition and capability data. This
  record keeps only display data and stable messaging references.
  """

  alias Jido.Messaging.{
    AgentDirectoryData,
    AgentDirectoryEndpointRef,
    AgentInvocationSummary
  }

  @availabilities [:unknown, :available, :unavailable, :degraded]
  @verification_states [:unverified, :verified, :rejected]
  @listing_states [:listed, :withdrawn]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              jidoka_agent_ref: Zoi.map(),
              principal_id: Zoi.string(),
              endpoint_ref: Zoi.struct(AgentDirectoryEndpointRef) |> Zoi.nullish(),
              name: Zoi.string(),
              description: Zoi.string() |> Zoi.nullish(),
              capabilities: Zoi.array(Zoi.string()),
              availability: Zoi.enum(@availabilities),
              version: Zoi.string(),
              invocation_summary: Zoi.struct(AgentInvocationSummary),
              verification_state: Zoi.enum(@verification_states),
              listing_state: Zoi.enum(@listing_states),
              source_revision: Zoi.integer(),
              source_updated_at: Zoi.struct(DateTime),
              fresh_until: Zoi.struct(DateTime),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type availability :: :unknown | :available | :unavailable | :degraded
  @type verification_state :: :unverified | :verified | :rejected
  @type listing_state :: :listed | :withdrawn
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @allowed_keys [
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
    :listing_state,
    :source_revision,
    :source_updated_at,
    :fresh_for_seconds
  ]

  @doc "Returns the Zoi schema for AgentDirectoryProjection."
  def schema, do: @schema

  @doc "Builds a strict projection from redacted Jidoka integration input."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    :ok = AgentDirectoryData.strict_keys!(attrs, @allowed_keys, "agent directory projection")
    now = DateTime.utc_now()
    jidoka_agent_ref = attrs |> AgentDirectoryData.value(:jidoka_agent_ref) |> AgentDirectoryData.jidoka_ref!()
    source_updated_at = attrs |> AgentDirectoryData.value(:source_updated_at) |> AgentDirectoryData.source_time!(now)
    fresh_seconds = attrs |> AgentDirectoryData.value(:fresh_for_seconds) |> AgentDirectoryData.fresh_seconds!()

    normalized = %{
      id: projection_id(jidoka_agent_ref["id"]),
      jidoka_agent_ref: jidoka_agent_ref,
      principal_id: attrs |> AgentDirectoryData.value(:principal_id) |> AgentDirectoryData.required_ref!(:principal_id),
      endpoint_ref: normalize_endpoint_ref(AgentDirectoryData.value(attrs, :endpoint_ref)),
      name: attrs |> AgentDirectoryData.value(:name) |> AgentDirectoryData.name!(),
      description: attrs |> AgentDirectoryData.value(:description) |> AgentDirectoryData.description!(),
      capabilities: attrs |> AgentDirectoryData.value(:capabilities, []) |> AgentDirectoryData.capabilities!(),
      availability:
        attrs
        |> AgentDirectoryData.value(:availability, :unknown)
        |> AgentDirectoryData.enum!(@availabilities, :availability),
      version: attrs |> AgentDirectoryData.value(:version) |> AgentDirectoryData.required_ref!(:version),
      invocation_summary: attrs |> AgentDirectoryData.value(:invocation_summary) |> AgentInvocationSummary.new(),
      verification_state:
        attrs
        |> AgentDirectoryData.value(:verification_state, :unverified)
        |> AgentDirectoryData.enum!(@verification_states, :verification_state),
      listing_state:
        attrs
        |> AgentDirectoryData.value(:listing_state, :listed)
        |> AgentDirectoryData.enum!(@listing_states, :listing_state),
      source_revision: attrs |> AgentDirectoryData.value(:source_revision) |> AgentDirectoryData.positive_revision!(),
      source_updated_at: source_updated_at,
      fresh_until: DateTime.add(source_updated_at, fresh_seconds, :second),
      inserted_at: now,
      updated_at: now
    }

    Jido.Chat.Schema.parse!(__MODULE__, @schema, normalized)
  end

  def new(_attrs), do: raise(ArgumentError, "agent directory projection must be a plain map")

  @doc "Tests whether two records contain the same source projection."
  @spec equivalent?(t(), t()) :: boolean()
  def equivalent?(%__MODULE__{} = left, %__MODULE__{} = right) do
    semantic_fields(left) == semantic_fields(right)
  end

  @doc "Tests whether two revisions identify the same Jidoka agent."
  @spec same_identity?(t(), t()) :: boolean()
  def same_identity?(%__MODULE__{} = left, %__MODULE__{} = right) do
    left.id == right.id and left.jidoka_agent_ref == right.jidoka_agent_ref
  end

  @doc false
  @spec preserve_insertion(t(), t()) :: t()
  def preserve_insertion(%__MODULE__{} = incoming, %__MODULE__{} = stored) do
    %{incoming | inserted_at: stored.inserted_at}
  end

  defp semantic_fields(projection) do
    projection
    |> Map.from_struct()
    |> Map.drop([:inserted_at, :updated_at])
  end

  defp normalize_endpoint_ref(nil), do: nil
  defp normalize_endpoint_ref(reference), do: AgentDirectoryEndpointRef.new(reference)

  defp projection_id(jidoka_agent_id) do
    digest =
      :crypto.hash(:sha256, "v1:jidoka:#{jidoka_agent_id}")
      |> Base.url_encode64(padding: false)

    "jadp_#{digest}"
  end
end
