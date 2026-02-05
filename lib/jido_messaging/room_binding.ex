defmodule JidoMessaging.RoomBinding do
  @moduledoc """
  Represents a binding between an internal room and an external platform room.

  Constraints:
  - Unique: {channel, instance_id, external_room_id} - one internal room per external
  - Non-unique: room_id - one internal room can have many external bindings

  ## Direction

  The `:direction` field controls message flow:
  - `:both` (default) - Messages flow in both directions
  - `:inbound` - Only receive messages from external platform
  - `:outbound` - Only send messages to external platform
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              channel: Zoi.atom(),
              instance_id: Zoi.string(),
              external_room_id: Zoi.string(),
              direction: Zoi.atom() |> Zoi.default(:both),
              enabled: Zoi.boolean() |> Zoi.default(true),
              inserted_at: Zoi.any()
            },
            coerce: false
          )

  @type direction :: :inbound | :outbound | :both

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  @doc """
  Create a new RoomBinding with auto-generated ID and timestamp.
  """
  def new(attrs) do
    attrs = Map.put_new(attrs, :id, generate_id())
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now())
    struct!(__MODULE__, attrs)
  end

  defp generate_id do
    "bind_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
