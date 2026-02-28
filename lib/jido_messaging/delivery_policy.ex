defmodule Jido.Messaging.DeliveryPolicy do
  @moduledoc """
  Per-bridge outbound retry/backoff policy.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              max_attempts: Zoi.integer() |> Zoi.default(3),
              base_backoff_ms: Zoi.integer() |> Zoi.default(25),
              max_backoff_ms: Zoi.integer() |> Zoi.default(500),
              dead_letter: Zoi.boolean() |> Zoi.default(true)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc "Builds a delivery policy from map attrs."
  @spec new(map()) :: t()
  def new(%__MODULE__{} = policy), do: policy

  def new(attrs) when is_map(attrs) do
    fields = Map.take(attrs, [:max_attempts, :base_backoff_ms, :max_backoff_ms, :dead_letter])
    struct!(__MODULE__, fields)
  end
end
