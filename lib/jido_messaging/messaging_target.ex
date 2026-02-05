defmodule JidoMessaging.MessagingTarget do
  @moduledoc """
  Canonical outbound message target.

  MessagingTarget provides a unified representation for outbound message routing,
  supporting DMs, groups, threads, and various reply modes. It abstracts away
  platform-specific targeting details while preserving the information needed
  for accurate message delivery.

  ## Reply Modes

    * `:inline` - Reply as a direct response in the same context
    * `:thread` - Reply in a thread (creates one if needed)
    * `:platform_default` - Use the platform's default reply behavior

  ## Usage

      # Create target from incoming context
      target = MessagingTarget.from_context(msg_context)

      # Create reply target with specific mode
      target = MessagingTarget.for_reply(msg_context, :thread)

      # Create target for a specific room
      target = MessagingTarget.for_room("external_room_123")
  """

  @type kind :: :room | :dm | :thread

  @type reply_mode :: :inline | :thread | :platform_default

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum([:room, :dm, :thread]) |> Zoi.default(:room),
              external_id: Zoi.string(),
              thread_id: Zoi.string() |> Zoi.nullish(),
              reply_to_mode: Zoi.enum([:inline, :thread, :platform_default]) |> Zoi.default(:platform_default),
              reply_to_id: Zoi.string() |> Zoi.nullish(),
              instance_id: Zoi.string() |> Zoi.nullish(),
              channel_type: Zoi.atom() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for MessagingTarget"
  def schema, do: @schema

  @doc """
  Creates a MessagingTarget from a MsgContext.

  The target kind is inferred from the chat type:
    * `:direct` chat type -> `:dm` kind
    * `:thread` chat type -> `:thread` kind
    * otherwise -> `:room` kind

  ## Examples

      iex> ctx = %MsgContext{external_room_id: "123", chat_type: :direct, ...}
      iex> target = MessagingTarget.from_context(ctx)
      iex> target.kind
      :dm
  """
  @spec from_context(JidoMessaging.MsgContext.t()) :: t()
  def from_context(%JidoMessaging.MsgContext{} = ctx) do
    kind = infer_kind(ctx.chat_type)

    struct!(__MODULE__, %{
      kind: kind,
      external_id: ctx.external_room_id,
      thread_id: ctx.external_thread_id,
      reply_to_mode: :platform_default,
      reply_to_id: ctx.external_message_id,
      instance_id: ctx.instance_id,
      channel_type: ctx.channel_type
    })
  end

  @doc """
  Creates a MessagingTarget configured for replying to a message.

  ## Parameters

    * `ctx` - The MsgContext of the message being replied to
    * `reply_mode` - How to reply: `:inline`, `:thread`, or `:platform_default`

  ## Examples

      # Reply in a thread
      target = MessagingTarget.for_reply(ctx, :thread)

      # Reply inline
      target = MessagingTarget.for_reply(ctx, :inline)
  """
  @spec for_reply(JidoMessaging.MsgContext.t(), reply_mode()) :: t()
  def for_reply(%JidoMessaging.MsgContext{} = ctx, reply_mode) do
    base = from_context(ctx)
    %{base | reply_to_mode: reply_mode}
  end

  @doc """
  Creates a MessagingTarget for a specific room/chat.

  Use this when sending a proactive message (not a reply).

  ## Examples

      target = MessagingTarget.for_room("chat_123")
      target = MessagingTarget.for_room("chat_123", kind: :dm, channel_type: :telegram)
  """
  @spec for_room(String.t(), keyword()) :: t()
  def for_room(external_id, opts \\ []) do
    struct!(__MODULE__, %{
      kind: Keyword.get(opts, :kind, :room),
      external_id: external_id,
      thread_id: Keyword.get(opts, :thread_id),
      reply_to_mode: :platform_default,
      reply_to_id: nil,
      instance_id: Keyword.get(opts, :instance_id),
      channel_type: Keyword.get(opts, :channel_type)
    })
  end

  @doc """
  Creates a MessagingTarget for a specific thread.

  ## Examples

      target = MessagingTarget.for_thread("chat_123", "thread_456")
  """
  @spec for_thread(String.t(), String.t(), keyword()) :: t()
  def for_thread(external_id, thread_id, opts \\ []) do
    struct!(__MODULE__, %{
      kind: :thread,
      external_id: external_id,
      thread_id: thread_id,
      reply_to_mode: Keyword.get(opts, :reply_to_mode, :platform_default),
      reply_to_id: Keyword.get(opts, :reply_to_id),
      instance_id: Keyword.get(opts, :instance_id),
      channel_type: Keyword.get(opts, :channel_type)
    })
  end

  @doc """
  Returns options suitable for passing to channel send_message functions.

  Converts the target into keyword options that channels can use.
  """
  @spec to_send_opts(t()) :: keyword()
  def to_send_opts(%__MODULE__{} = target) do
    opts = []

    opts =
      if target.reply_to_id do
        Keyword.put(opts, :reply_to_id, target.reply_to_id)
      else
        opts
      end

    opts =
      if target.thread_id do
        Keyword.put(opts, :thread_id, target.thread_id)
      else
        opts
      end

    opts =
      if target.reply_to_mode != :platform_default do
        Keyword.put(opts, :reply_mode, target.reply_to_mode)
      else
        opts
      end

    opts
  end

  defp infer_kind(:direct), do: :dm
  defp infer_kind(:thread), do: :thread
  defp infer_kind(_), do: :room
end
