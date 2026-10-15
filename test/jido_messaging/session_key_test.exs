defmodule Jido.Messaging.SessionKeyTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{MsgContext, SessionKey}

  defmodule MockChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :mock

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _payload), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: 999}}
  end

  describe "from_context/1" do
    test "uses the resolved room_id when available" do
      ctx =
        base_context()
        |> Map.put(:room_id, "room_uuid_456")

      assert SessionKey.from_context(ctx) == {:mock, "instance_1", "room_uuid_456", nil}
    end

    test "uses thread_id when present" do
      ctx =
        base_context()
        |> Map.put(:room_id, "room_uuid")
        |> Map.put(:thread_id, "thread_123")

      assert SessionKey.from_context(ctx) == {:mock, "instance_1", "room_uuid", "thread_123"}
    end

    test "falls back to external_thread_id when thread_id is absent" do
      ctx =
        base_context()
        |> Map.put(:external_thread_id, "ext-thread-123")

      assert SessionKey.from_context(ctx) == {:mock, "instance_1", "chat_123", "ext-thread-123"}
    end
  end

  describe "to_string/1" do
    test "formats keys without a thread" do
      assert SessionKey.to_string({:telegram, "bot_1", "chat_123", nil}) ==
               "telegram:bot_1:chat_123"
    end

    test "formats keys with a thread" do
      assert SessionKey.to_string({:discord, "guild_1", "channel_456", "thread_789"}) ==
               "discord:guild_1:channel_456:thread_789"
    end
  end

  describe "parse/1" do
    test "parses a key without thread scope" do
      _ = :telegram

      assert SessionKey.parse("telegram:bot_1:chat_123") ==
               {:ok, {:telegram, "bot_1", "chat_123", nil}}
    end

    test "parses a key with thread scope" do
      _ = :discord

      assert SessionKey.parse("discord:guild_1:ch_1:thread_456") ==
               {:ok, {:discord, "guild_1", "ch_1", "thread_456"}}
    end

    test "rejects invalid formats" do
      assert SessionKey.parse("invalid") == {:error, :invalid_format}
      assert SessionKey.parse("only:two") == {:error, :invalid_format}
      assert SessionKey.parse("nonexistent_channel_type_xyz:bot:room") == {:error, :invalid_format}
    end
  end

  describe "same_room?/2" do
    test "ignores thread scope when comparing room identity" do
      key1 = {:telegram, "bot_1", "chat_123", nil}
      key2 = {:telegram, "bot_1", "chat_123", "thread_456"}
      key3 = {:telegram, "bot_1", "chat_123", "thread_789"}

      assert SessionKey.same_room?(key1, key2)
      assert SessionKey.same_room?(key2, key3)
    end

    test "returns false across different rooms, instances, or channel types" do
      refute SessionKey.same_room?({:telegram, "bot_1", "chat_123", nil}, {:telegram, "bot_1", "chat_456", nil})
      refute SessionKey.same_room?({:telegram, "bot_1", "chat_123", nil}, {:telegram, "bot_2", "chat_123", nil})
      refute SessionKey.same_room?({:telegram, "bot_1", "chat_123", nil}, {:discord, "bot_1", "chat_123", nil})
    end
  end

  defp base_context do
    MsgContext.from_incoming(MockChannel, "instance_1", %{
      external_room_id: "chat_123",
      external_user_id: "user_456",
      text: "Hello"
    })
  end
end
