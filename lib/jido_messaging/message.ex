defmodule JidoMessaging.Message do
  @moduledoc """
  Represents a message in the messaging system.

  Messages have an LLM-native structure with role-based identification
  and content as a list of content blocks (text, tool calls, etc.).
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              room_id: Zoi.string(),
              sender_id: Zoi.string(),
              role: Zoi.enum([:user, :assistant, :system, :tool]),
              content: Zoi.array(Zoi.map()) |> Zoi.default([]),
              reply_to_id: Zoi.string() |> Zoi.nullish(),
              status: Zoi.enum([:sending, :sent, :delivered, :read, :failed]) |> Zoi.default(:sending),
              metadata: Zoi.map() |> Zoi.default(%{}),
              inserted_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              updated_at: Zoi.struct(DateTime) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Message"
  def schema, do: @schema

  @doc "Creates a new message with generated ID and timestamps"
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs
    |> Map.put_new(:id, generate_id())
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
    |> then(&struct!(__MODULE__, &1))
  end

  defp generate_id, do: "msg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
