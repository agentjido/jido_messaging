defmodule Jido.Messaging.AgentMessagingEndpoint do
  @moduledoc """
  Durable messaging endpoint for one Jidoka agent principal.

  The record contains an opaque Jidoka agent reference. It does not contain an
  agent definition, handler, process, model, tool, prompt, credential, memory,
  or runtime state.
  """

  alias Jido.Messaging.AgentEndpointData

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              principal_id: Zoi.string(),
              jidoka_agent_ref: Zoi.map(),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              availability: Zoi.enum([:unknown, :available, :unavailable, :degraded]) |> Zoi.default(:unknown),
              availability_ref: Zoi.string() |> Zoi.nullish(),
              last_seen_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type availability :: :unknown | :available | :unavailable | :degraded
  @type status :: :active | :suspended | :revoked
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AgentMessagingEndpoint."
  def schema, do: @schema

  @doc "Creates a safe durable endpoint record for a Jidoka agent."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.put(:principal_id, attrs |> value(:principal_id) |> AgentEndpointData.normalize_required!(:principal_id))
    |> Map.put(:jidoka_agent_ref, attrs |> value(:jidoka_agent_ref) |> AgentEndpointData.normalize_jidoka_ref!())
    |> Map.put(
      :availability_ref,
      attrs |> value(:availability_ref) |> AgentEndpointData.normalize_optional!(:availability_ref)
    )
    |> Map.put(:metadata, attrs |> value(:metadata, %{}) |> AgentEndpointData.validate_metadata!())
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Updates the endpoint availability projection without contacting Jidoka."
  @spec set_availability(t(), availability(), keyword()) :: {:ok, t()} | {:error, term()}
  def set_availability(endpoint, availability, opts \\ [])

  def set_availability(%__MODULE__{status: :revoked}, :available, _opts),
    do: {:error, :endpoint_revoked}

  def set_availability(%__MODULE__{} = endpoint, availability, opts)
      when availability in [:unknown, :available, :unavailable, :degraded] and is_list(opts) do
    now = DateTime.utc_now()

    attrs =
      endpoint
      |> Map.from_struct()
      |> Map.put(:availability, availability)
      |> Map.put(
        :availability_ref,
        opts
        |> Keyword.get(:availability_ref, endpoint.availability_ref)
        |> AgentEndpointData.normalize_optional!(:availability_ref)
      )
      |> Map.put(
        :last_seen_at,
        Keyword.get(opts, :last_seen_at, maybe_last_seen_at(endpoint, availability, now))
      )
      |> Map.put(:updated_at, now)

    {:ok, new(attrs)}
  end

  def set_availability(%__MODULE__{}, availability, _opts),
    do: {:error, {:invalid_endpoint_availability, availability}}

  @doc "Marks the endpoint as revoked and unavailable."
  @spec revoke(t(), DateTime.t()) :: t()
  def revoke(%__MODULE__{} = endpoint, revoked_at \\ DateTime.utc_now()) do
    %{
      endpoint
      | status: :revoked,
        availability: :unavailable,
        updated_at: revoked_at
    }
  end

  defp maybe_last_seen_at(_endpoint, :available, now), do: now
  defp maybe_last_seen_at(endpoint, _availability, _now), do: endpoint.last_seen_at

  defp value(map, key, default \\ nil),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
end
