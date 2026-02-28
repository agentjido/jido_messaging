defmodule Jido.Messaging.SessionKey do
  @moduledoc """
  Session key derivation for conversation scoping.

  Provides a canonical way to derive a unique session identifier from a message context.
  This enables applications to scope conversations by channel, bridge, room, and optionally thread.

  The session key is a tuple that can be used as a process registry key, ETS key,
  or any other lookup mechanism that requires a unique conversation identifier.

  ## Usage

      # Derive session key from message context
      key = SessionKey.from_context(msg_context)
      #=> {:telegram, "bot_123", "chat_456", nil}

      # With thread scoping
      key = SessionKey.from_context(threaded_msg_context)
      #=> {:telegram, "bot_123", "chat_456", "thread_789"}

      # Convert to string for string-keyed stores
      SessionKey.to_string(key)
      #=> "telegram:bot_123:chat_456"
  """

  alias Jido.Messaging.MsgContext

  @type t :: {
          channel_type :: atom(),
          bridge_id :: String.t(),
          room_id :: String.t(),
          thread_id :: String.t() | nil
        }

  @doc """
  Derives a session key from a MsgContext.

  Uses `room_id` if resolved (internal UUID), otherwise falls back to `external_room_id`.
  Thread scoping uses `thread_root_id` if present.

  ## Examples

      iex> ctx = %MsgContext{channel_type: :telegram, bridge_id: "bot_1", external_room_id: "123", room_id: nil, thread_root_id: nil}
      iex> SessionKey.from_context(ctx)
      {:telegram, "bot_1", "123", nil}

      iex> ctx = %MsgContext{channel_type: :discord, bridge_id: "guild_1", external_room_id: "ch_1", room_id: "uuid-123", thread_root_id: "thread_456"}
      iex> SessionKey.from_context(ctx)
      {:discord, "guild_1", "uuid-123", "thread_456"}
  """
  @spec from_context(MsgContext.t()) :: t()
  def from_context(%MsgContext{} = ctx) do
    room_id = ctx.room_id || ctx.external_room_id
    {ctx.channel_type, ctx.bridge_id, room_id, ctx.thread_root_id}
  end

  @doc """
  Converts a session key to a string representation.

  Useful for string-keyed stores like Redis or as a log identifier.
  Thread ID is omitted if nil.

  ## Examples

      iex> SessionKey.to_string({:telegram, "bot_1", "chat_123", nil})
      "telegram:bot_1:chat_123"

      iex> SessionKey.to_string({:discord, "guild_1", "ch_1", "thread_456"})
      "discord:guild_1:ch_1:thread_456"
  """
  @spec to_string(t()) :: String.t()
  def to_string({channel_type, bridge_id, room_id, nil}) do
    "#{channel_type}:#{bridge_id}:#{room_id}"
  end

  def to_string({channel_type, bridge_id, room_id, thread_id}) do
    "#{channel_type}:#{bridge_id}:#{room_id}:#{thread_id}"
  end

  @doc """
  Parses a string representation back into a session key tuple.

  Returns `{:ok, key}` on success, `{:error, :invalid_format}` on failure.

  ## Examples

      iex> SessionKey.parse("telegram:bot_1:chat_123")
      {:ok, {:telegram, "bot_1", "chat_123", nil}}

      iex> SessionKey.parse("discord:guild_1:ch_1:thread_456")
      {:ok, {:discord, "guild_1", "ch_1", "thread_456"}}

      iex> SessionKey.parse("invalid")
      {:error, :invalid_format}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_format}
  def parse(str) when is_binary(str) do
    case String.split(str, ":") do
      [channel_type, bridge_id, room_id] ->
        {:ok, {String.to_existing_atom(channel_type), bridge_id, room_id, nil}}

      [channel_type, bridge_id, room_id, thread_id] ->
        {:ok, {String.to_existing_atom(channel_type), bridge_id, room_id, thread_id}}

      _ ->
        {:error, :invalid_format}
    end
  rescue
    ArgumentError -> {:error, :invalid_format}
  end

  @doc """
  Checks if two session keys belong to the same conversation scope.

  Two keys match if channel_type, bridge_id, and room_id are equal.
  Thread IDs are not compared (both threaded and non-threaded messages in the same room match).

  ## Examples

      iex> key1 = {:telegram, "bot_1", "chat_123", nil}
      iex> key2 = {:telegram, "bot_1", "chat_123", "thread_456"}
      iex> SessionKey.same_room?(key1, key2)
      true

      iex> key1 = {:telegram, "bot_1", "chat_123", nil}
      iex> key2 = {:telegram, "bot_1", "chat_456", nil}
      iex> SessionKey.same_room?(key1, key2)
      false
  """
  @spec same_room?(t(), t()) :: boolean()
  def same_room?(
        {channel1, bridge1, room1, _thread1},
        {channel2, bridge2, room2, _thread2}
      ) do
    channel1 == channel2 and bridge1 == bridge2 and room1 == room2
  end
end
