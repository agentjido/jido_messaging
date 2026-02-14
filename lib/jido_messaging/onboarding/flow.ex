defmodule JidoMessaging.Onboarding.Flow do
  @moduledoc """
  Persisted onboarding flow state.

  Flow state is append-only with explicit transition history and persisted
  idempotency records so retries do not duplicate side effects.
  """

  @statuses [:started, :directory_resolved, :paired, :completed, :cancelled]

  @schema Zoi.struct(
            __MODULE__,
            %{
              onboarding_id: Zoi.string(),
              status: Zoi.enum(@statuses),
              request: Zoi.map() |> Zoi.default(%{}),
              directory_match: Zoi.map() |> Zoi.nullish(),
              pairing: Zoi.map() |> Zoi.nullish(),
              completion_metadata: Zoi.map() |> Zoi.nullish(),
              transitions: Zoi.array(Zoi.map()) |> Zoi.default([]),
              idempotency: Zoi.map() |> Zoi.default(%{}),
              side_effects: Zoi.array(Zoi.map()) |> Zoi.default([]),
              inserted_at: Zoi.struct(DateTime),
              updated_at: Zoi.struct(DateTime)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc "Creates a new onboarding flow in the `:started` state."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.put_new(:onboarding_id, Jido.Signal.ID.generate!())
    |> Map.put_new(:status, :started)
    |> Map.put_new(:request, %{})
    |> Map.put_new(:transitions, [])
    |> Map.put_new(:idempotency, %{})
    |> Map.put_new(:side_effects, [])
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&struct!(__MODULE__, &1))
  end
end
