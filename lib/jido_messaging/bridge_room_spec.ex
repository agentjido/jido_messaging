defmodule Jido.Messaging.BridgeRoomSpec do
  @moduledoc """
  Declarative spec for creating a bridge-backed room topology.

  This bundles room definition, optional bridge configs, room bindings,
  and routing policy into one idempotent API payload.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              room_id: Zoi.string() |> Zoi.nullish(),
              room_type: Zoi.enum([:direct, :group, :channel, :thread]) |> Zoi.default(:group),
              room_name: Zoi.string() |> Zoi.nullish(),
              room_metadata: Zoi.map() |> Zoi.default(%{}),
              bridge_configs: Zoi.array(Zoi.map()) |> Zoi.default([]),
              bindings: Zoi.array(Zoi.map()) |> Zoi.default([]),
              routing_policy: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for BridgeRoomSpec."
  def schema, do: @schema

  @doc "Creates a BridgeRoomSpec from a map."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)
end
