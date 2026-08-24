defmodule Jido.Messaging.RoomMembership do
  @moduledoc """
  Durable room membership for a messaging principal and agent endpoint.

  Membership records scope an endpoint to a room. They do not grant messaging
  actions. Principal grants and invocation policy are separate contracts.
  """

  alias Jido.Messaging.AgentEndpointData

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              principal_id: Zoi.string(),
              endpoint_id: Zoi.string(),
              status: Zoi.enum([:active, :suspended, :revoked]) |> Zoi.default(:active),
              joined_at: Zoi.struct(DateTime),
              ended_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for RoomMembership."
  def schema, do: @schema

  @doc "Creates an agent endpoint membership for one room."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.put(:room_id, attrs |> value(:room_id) |> AgentEndpointData.normalize_required!(:room_id))
    |> Map.put(:principal_id, attrs |> value(:principal_id) |> AgentEndpointData.normalize_required!(:principal_id))
    |> Map.put(:endpoint_id, attrs |> value(:endpoint_id) |> AgentEndpointData.normalize_required!(:endpoint_id))
    |> Map.put(:metadata, attrs |> value(:metadata, %{}) |> AgentEndpointData.validate_metadata!())
    |> Map.put_new(:id, Jido.Chat.ID.generate!())
    |> Map.put_new(:joined_at, now)
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Revokes a room membership without deleting its audit record."
  @spec revoke(t(), DateTime.t()) :: t()
  def revoke(%__MODULE__{} = membership, ended_at \\ DateTime.utc_now()) do
    %{membership | status: :revoked, ended_at: ended_at, updated_at: ended_at}
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
end
