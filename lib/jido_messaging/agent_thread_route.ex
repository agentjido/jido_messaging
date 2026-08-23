defmodule Jido.Messaging.AgentThreadRoute do
  @moduledoc """
  Durable route from one messaging thread to one Jidoka agent endpoint.

  Jidoka correlation fields are opaque references. They do not contain a
  session, request, turn, snapshot, memory entry, or runtime event.
  """

  alias Jido.Messaging.AgentEndpointData

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              thread_id: Zoi.string(),
              endpoint_id: Zoi.string(),
              status: Zoi.enum([:active, :paused, :revoked]) |> Zoi.default(:active),
              jidoka_session_ref: Zoi.string() |> Zoi.nullish(),
              jidoka_request_ref: Zoi.string() |> Zoi.nullish(),
              jidoka_turn_ref: Zoi.string() |> Zoi.nullish(),
              delivery_revision: Zoi.integer() |> Zoi.default(0),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for AgentThreadRoute."
  def schema, do: @schema

  @doc "Creates a durable thread route to an agent endpoint."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    delivery_revision = value(attrs, :delivery_revision, 0)

    if not is_integer(delivery_revision) or delivery_revision < 0 do
      raise ArgumentError, "delivery_revision must be a non-negative integer"
    end

    attrs
    |> Map.put(:room_id, attrs |> value(:room_id) |> AgentEndpointData.normalize_required!(:room_id))
    |> Map.put(:thread_id, attrs |> value(:thread_id) |> AgentEndpointData.normalize_required!(:thread_id))
    |> Map.put(:endpoint_id, attrs |> value(:endpoint_id) |> AgentEndpointData.normalize_required!(:endpoint_id))
    |> normalize_correlation(:jidoka_session_ref)
    |> normalize_correlation(:jidoka_request_ref)
    |> normalize_correlation(:jidoka_turn_ref)
    |> Map.put(:delivery_revision, delivery_revision)
    |> Map.put(:metadata, attrs |> value(:metadata, %{}) |> AgentEndpointData.validate_metadata!())
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Updates opaque Jidoka correlation references and increments the delivery revision."
  @spec put_correlations(t(), map()) :: t()
  def put_correlations(%__MODULE__{} = route, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    route
    |> Map.from_struct()
    |> maybe_put_correlation(attrs, :jidoka_session_ref)
    |> maybe_put_correlation(attrs, :jidoka_request_ref)
    |> maybe_put_correlation(attrs, :jidoka_turn_ref)
    |> Map.put(:delivery_revision, route.delivery_revision + 1)
    |> Map.put(:updated_at, now)
    |> new()
  end

  @doc "Revokes a thread route without deleting its audit identity."
  @spec revoke(t(), DateTime.t()) :: t()
  def revoke(%__MODULE__{} = route, revoked_at \\ DateTime.utc_now()) do
    %{route | status: :revoked, updated_at: revoked_at}
  end

  defp normalize_correlation(attrs, key) do
    Map.put(attrs, key, attrs |> value(key) |> AgentEndpointData.normalize_optional!(key))
  end

  defp maybe_put_correlation(result, attrs, key) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
      Map.put(result, key, attrs |> value(key) |> AgentEndpointData.normalize_optional!(key))
    else
      result
    end
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
end
