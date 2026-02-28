defmodule Jido.Messaging.BridgeStatus do
  @moduledoc """
  Runtime bridge health/status snapshot.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              bridge_id: Zoi.string(),
              adapter_module: Zoi.module(),
              enabled: Zoi.boolean(),
              revision: Zoi.integer(),
              listener_count: Zoi.integer(),
              last_ingress_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              last_outbound_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              last_error: Zoi.any() |> Zoi.nullish()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc "Builds a bridge status from attrs."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)
end
