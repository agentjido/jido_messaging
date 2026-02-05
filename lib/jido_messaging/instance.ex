defmodule JidoMessaging.Instance do
  @moduledoc """
  Represents a channel instance (e.g., a Telegram bot, Discord connection).

  Instances manage connections to external messaging platforms and
  maintain their own credentials and settings.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              name: Zoi.string(),
              channel_type: Zoi.enum([:telegram, :discord, :slack, :whatsapp, :internal]),
              status: Zoi.enum([:connected, :disconnected, :connecting, :error]) |> Zoi.default(:disconnected),
              credentials: Zoi.map() |> Zoi.default(%{}),
              settings: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Instance"
  def schema, do: @schema

  @doc "Creates a new instance with generated ID and timestamp"
  def new(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:id, Jido.Signal.ID.generate!())
    |> Map.put_new(:inserted_at, DateTime.utc_now())
    |> then(&struct!(__MODULE__, &1))
  end
end
