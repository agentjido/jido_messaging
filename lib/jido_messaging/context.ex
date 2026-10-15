defmodule Jido.Messaging.Context do
  @moduledoc """
  Canonical runtime delivery context for `Jido.Messaging`.
  """

  @behaviour Access

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{MsgContext, Thread}

  @schema Zoi.struct(
            __MODULE__,
            %{
              room: Zoi.struct(Room),
              participant: Zoi.struct(Participant),
              thread: Zoi.struct(Thread) |> Zoi.nullish(),
              channel: Zoi.module(),
              bridge_id: Zoi.string(),
              channel_type: Zoi.atom() |> Zoi.nullish(),
              external_room_id: Zoi.string(),
              external_thread_id: Zoi.string() |> Zoi.nullish(),
              delivery_external_room_id: Zoi.string() |> Zoi.nullish(),
              room_id: Zoi.string(),
              thread_id: Zoi.string() |> Zoi.nullish(),
              participant_id: Zoi.string(),
              instance_module: Zoi.module(),
              parent_signal: Zoi.struct(Jido.Signal) |> Zoi.nullish(),
              msg_context: Zoi.struct(MsgContext)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Context."
  def schema, do: @schema

  @doc "Creates a context struct from map input."
  def new(attrs) when is_map(attrs), do: Jido.Chat.Schema.parse!(__MODULE__, @schema, attrs)

  @doc false
  def fetch(%__MODULE__{} = context, key), do: Map.fetch(context, key)

  @doc false
  def get_and_update(%__MODULE__{} = context, key, function) do
    Map.get_and_update(context, key, function)
  end

  @doc false
  def pop(%__MODULE__{} = context, key), do: Map.pop(context, key)
end
