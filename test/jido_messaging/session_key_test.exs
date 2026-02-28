defmodule Jido.Messaging.SessionKeyTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.SessionKey
  alias Jido.Messaging.MsgContext

  defmodule MockChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :mock

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: 999}}
  end

  describe "from_context/1" do
    test "derives key from MsgContext with external IDs" do
      ctx = build_context()
      key = SessionKey.from_context(ctx)

      assert key == {:mock, "instance_1", "chat_123", nil}
    end

    test "prefers room_id over external_room_id when resolved" do
      ctx =
        build_context()
        |> resolve_room("room_uuid_456")

      key = SessionKey.from_context(ctx)

      assert key == {:mock, "instance_1", "room_uuid_456", nil}
    end

    test "includes thread_root_id when present" do
      ctx =
        build_context()
        |> resolve_room("room_uuid")
        |> with_thread("thread_root_123")

      key = SessionKey.from_context(ctx)

      assert key == {:mock, "instance_1", "room_uuid", "thread_root_123"}
    end
  end

  describe "to_string/1" do
    test "formats key without thread" do
      key = {:telegram, "bot_1", "chat_123", nil}
      assert SessionKey.to_string(key) == "telegram:bot_1:chat_123"
    end

    test "formats key with thread" do
      key = {:discord, "guild_1", "channel_456", "thread_789"}
      assert SessionKey.to_string(key) == "discord:guild_1:channel_456:thread_789"
    end
  end

  describe "parse/1" do
    test "parses string without thread" do
      # Ensure atom exists
      _ = :telegram
      assert {:ok, {:telegram, "bot_1", "chat_123", nil}} == SessionKey.parse("telegram:bot_1:chat_123")
    end

    test "parses string with thread" do
      _ = :discord
      assert {:ok, {:discord, "guild_1", "ch_1", "thread_456"}} == SessionKey.parse("discord:guild_1:ch_1:thread_456")
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_format} == SessionKey.parse("invalid")
      assert {:error, :invalid_format} == SessionKey.parse("only:two")
    end

    test "returns error for non-existent atom" do
      assert {:error, :invalid_format} == SessionKey.parse("nonexistent_channel_type_xyz:bot:room")
    end
  end

  describe "same_room?/2" do
    test "returns true for same room regardless of thread" do
      key1 = {:telegram, "bot_1", "chat_123", nil}
      key2 = {:telegram, "bot_1", "chat_123", "thread_456"}

      assert SessionKey.same_room?(key1, key2)
      assert SessionKey.same_room?(key2, key1)
    end

    test "returns true for same room with different threads" do
      key1 = {:telegram, "bot_1", "chat_123", "thread_1"}
      key2 = {:telegram, "bot_1", "chat_123", "thread_2"}

      assert SessionKey.same_room?(key1, key2)
    end

    test "returns false for different rooms" do
      key1 = {:telegram, "bot_1", "chat_123", nil}
      key2 = {:telegram, "bot_1", "chat_456", nil}

      refute SessionKey.same_room?(key1, key2)
    end

    test "returns false for different instances" do
      key1 = {:telegram, "bot_1", "chat_123", nil}
      key2 = {:telegram, "bot_2", "chat_123", nil}

      refute SessionKey.same_room?(key1, key2)
    end

    test "returns false for different channel types" do
      key1 = {:telegram, "bot_1", "chat_123", nil}
      key2 = {:discord, "bot_1", "chat_123", nil}

      refute SessionKey.same_room?(key1, key2)
    end
  end

  # Helper functions

  defp build_context do
    incoming = %{
      external_room_id: "chat_123",
      external_user_id: "user_456",
      text: "Hello"
    }

    MsgContext.from_incoming(MockChannel, "instance_1", incoming)
  end

  defp resolve_room(ctx, room_id) do
    %{ctx | room_id: room_id}
  end

  defp with_thread(ctx, thread_root_id) do
    %{ctx | thread_root_id: thread_root_id}
  end
end
