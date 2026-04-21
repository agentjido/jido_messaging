defmodule Jido.Messaging.MsgContext do
  @moduledoc """
  Normalized message envelope for routing and transport.

  MsgContext provides a unified, typed representation of an inbound/outbound message
  that can be used consistently across all pipeline stages. It contains channel
  identification, conversation scope, sender identity, message identification,
  threading context, and extensible metadata.

  ## Usage

      # Populated by Ingest pipeline
      {:ok, message, msg_context} = Ingest.ingest_incoming(messaging, channel, bridge_id, incoming)

      # Use for routing decisions
      if msg_context.chat_type == :direct do
        # Handle DM
      end

      # Build reply target
      target = MessagingTarget.from_context(msg_context)
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              # Channel identification
              channel_type: Zoi.atom(),
              channel_module: Zoi.module() |> Zoi.nullish(),
              bridge_id: Zoi.string(),

              # Conversation scope
              external_room_id: Zoi.string(),
              room_id: Zoi.string() |> Zoi.nullish(),
              chat_type: Zoi.enum([:direct, :group, :channel, :thread]) |> Zoi.default(:direct),

              # Sender identity
              external_user_id: Zoi.string(),
              participant_id: Zoi.string() |> Zoi.nullish(),
              sender_name: Zoi.string() |> Zoi.nullish(),
              sender_username: Zoi.string() |> Zoi.nullish(),

              # Message identification
              external_message_id: Zoi.string() |> Zoi.nullish(),
              message_id: Zoi.string() |> Zoi.nullish(),
              body: Zoi.string() |> Zoi.nullish(),

              # Threading
              reply_to_id: Zoi.string() |> Zoi.nullish(),
              external_reply_to_id: Zoi.string() |> Zoi.nullish(),
              thread_id: Zoi.string() |> Zoi.nullish(),
              external_thread_id: Zoi.string() |> Zoi.nullish(),
              delivery_external_room_id: Zoi.string() |> Zoi.nullish(),

              # Mention tracking
              was_mentioned: Zoi.boolean() |> Zoi.default(false),
              mentions: Zoi.array(Zoi.map()) |> Zoi.default([]),
              agent_mentions: Zoi.array(Zoi.string()) |> Zoi.default([]),

              # Parsed command (populated by application/channel)
              command: Zoi.map() |> Zoi.nullish(),

              # Extensible metadata (namespaced)
              channel_meta: Zoi.map() |> Zoi.default(%{}),
              app_meta: Zoi.map() |> Zoi.default(%{}),

              # Timestamps
              timestamp: Zoi.integer() |> Zoi.nullish(),

              # Raw payload for debugging/channel-specific needs
              raw: Zoi.map() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for MsgContext"
  def schema, do: @schema

  @doc """
  Creates a new MsgContext from incoming message data.

  ## Parameters

    * `channel_module` - The channel module that received the message
    * `bridge_id` - The bridge identifier
    * `incoming` - The normalized incoming message map

  ## Examples

      iex> incoming = %{
      ...>   external_room_id: "chat_123",
      ...>   external_user_id: "user_456",
      ...>   text: "Hello"
      ...> }
      iex> ctx = MsgContext.from_incoming(MyChannel, "bot_1", incoming)
      iex> ctx.external_room_id
      "chat_123"
  """
  @spec from_incoming(module(), String.t(), map()) :: t()
  def from_incoming(channel_module, bridge_id, incoming) do
    channel_type = channel_module.channel_type()

    attrs = %{
      # Channel identification
      channel_type: channel_type,
      channel_module: channel_module,
      bridge_id: to_string(bridge_id),

      # Conversation scope
      external_room_id: to_string(incoming.external_room_id),
      chat_type: map_chat_type(Map.get(incoming, :chat_type)),

      # Sender identity
      external_user_id: to_string(incoming.external_user_id),
      sender_name: Map.get(incoming, :display_name),
      sender_username: Map.get(incoming, :username),

      # Message identification
      external_message_id: stringify_if_present(Map.get(incoming, :external_message_id)),
      body: Map.get(incoming, :text),

      # Threading
      external_reply_to_id: stringify_if_present(Map.get(incoming, :external_reply_to_id)),
      external_thread_id: stringify_if_present(Map.get(incoming, :external_thread_id)),
      delivery_external_room_id:
        stringify_if_present(Map.get(incoming, :delivery_external_room_id) || Map.get(incoming, :external_room_id)),

      # Mention tracking
      was_mentioned: Map.get(incoming, :was_mentioned) || false,
      mentions: Map.get(incoming, :mentions) || [],

      # Metadata
      channel_meta: Map.get(incoming, :channel_meta) || %{},
      timestamp: Map.get(incoming, :timestamp),
      raw: Map.get(incoming, :raw)
    }

    struct!(__MODULE__, attrs)
  end

  @doc """
  Enriches the MsgContext with resolved internal IDs after room/participant lookup.

  ## Parameters

    * `ctx` - The MsgContext to enrich
    * `room` - The resolved Room struct
    * `participant` - The resolved Participant struct
    * `message` - The persisted Message struct
  """
  @spec with_resolved(t(), map(), map(), map()) :: t()
  def with_resolved(%__MODULE__{} = ctx, room, participant, message) do
    %{
      ctx
      | room_id: room.id,
        participant_id: participant.id,
        message_id: message.id,
        reply_to_id: message.reply_to_id,
        thread_id: message.thread_id,
        external_thread_id: message.external_thread_id || ctx.external_thread_id,
        delivery_external_room_id: message.delivery_external_room_id || ctx.delivery_external_room_id
    }
  end

  defp map_chat_type(:private), do: :direct
  defp map_chat_type(:group), do: :group
  defp map_chat_type(:supergroup), do: :group
  defp map_chat_type(:channel), do: :channel
  defp map_chat_type(:thread), do: :thread
  defp map_chat_type(:direct), do: :direct
  defp map_chat_type(_), do: :direct

  defp stringify_if_present(nil), do: nil
  defp stringify_if_present(value), do: to_string(value)
end
