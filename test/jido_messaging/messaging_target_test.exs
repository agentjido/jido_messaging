defmodule JidoMessaging.MessagingTargetTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.{MessagingTarget, MsgContext}

  defmodule MockChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :mock

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: 999}}
  end

  describe "schema/0" do
    test "returns Zoi schema" do
      schema = MessagingTarget.schema()
      assert is_map(schema)
    end
  end

  describe "from_context/1" do
    test "creates target from MsgContext with direct chat" do
      ctx = build_msg_context(chat_type: :direct)

      target = MessagingTarget.from_context(ctx)

      assert target.kind == :dm
      assert target.external_id == "chat_123"
      assert target.reply_to_id == "msg_456"
      assert target.instance_id == "instance_1"
      assert target.channel_type == :mock
      assert target.reply_to_mode == :platform_default
    end

    test "creates target from MsgContext with group chat" do
      ctx = build_msg_context(chat_type: :group)

      target = MessagingTarget.from_context(ctx)

      assert target.kind == :room
      assert target.external_id == "chat_123"
    end

    test "creates target from MsgContext with thread" do
      ctx = build_msg_context(chat_type: :thread, external_thread_id: "thread_789")

      target = MessagingTarget.from_context(ctx)

      assert target.kind == :thread
      assert target.thread_id == "thread_789"
    end

    test "creates target from MsgContext with channel chat" do
      ctx = build_msg_context(chat_type: :channel)

      target = MessagingTarget.from_context(ctx)

      assert target.kind == :room
    end
  end

  describe "for_reply/2" do
    test "creates reply target with inline mode" do
      ctx = build_msg_context()

      target = MessagingTarget.for_reply(ctx, :inline)

      assert target.reply_to_mode == :inline
      assert target.reply_to_id == "msg_456"
      assert target.external_id == "chat_123"
    end

    test "creates reply target with thread mode" do
      ctx = build_msg_context()

      target = MessagingTarget.for_reply(ctx, :thread)

      assert target.reply_to_mode == :thread
    end

    test "creates reply target with platform_default mode" do
      ctx = build_msg_context()

      target = MessagingTarget.for_reply(ctx, :platform_default)

      assert target.reply_to_mode == :platform_default
    end
  end

  describe "for_room/2" do
    test "creates target for room with defaults" do
      target = MessagingTarget.for_room("external_123")

      assert target.kind == :room
      assert target.external_id == "external_123"
      assert target.reply_to_mode == :platform_default
      assert target.reply_to_id == nil
      assert target.thread_id == nil
    end

    test "creates target for room with options" do
      target =
        MessagingTarget.for_room("external_123",
          kind: :dm,
          channel_type: :telegram,
          instance_id: "bot_1"
        )

      assert target.kind == :dm
      assert target.channel_type == :telegram
      assert target.instance_id == "bot_1"
    end

    test "creates target for room with thread_id option" do
      target = MessagingTarget.for_room("external_123", thread_id: "thread_456")

      assert target.thread_id == "thread_456"
    end
  end

  describe "for_thread/3" do
    test "creates target for thread" do
      target = MessagingTarget.for_thread("chat_123", "thread_456")

      assert target.kind == :thread
      assert target.external_id == "chat_123"
      assert target.thread_id == "thread_456"
      assert target.reply_to_mode == :platform_default
    end

    test "creates target for thread with options" do
      target =
        MessagingTarget.for_thread("chat_123", "thread_456",
          reply_to_mode: :inline,
          reply_to_id: "msg_789",
          instance_id: "bot_1",
          channel_type: :slack
        )

      assert target.reply_to_mode == :inline
      assert target.reply_to_id == "msg_789"
      assert target.instance_id == "bot_1"
      assert target.channel_type == :slack
    end
  end

  describe "to_send_opts/1" do
    test "returns empty list for default target" do
      target = MessagingTarget.for_room("chat_123")

      opts = MessagingTarget.to_send_opts(target)

      assert opts == []
    end

    test "includes reply_to_id when present" do
      ctx = build_msg_context()
      target = MessagingTarget.from_context(ctx)

      opts = MessagingTarget.to_send_opts(target)

      assert Keyword.get(opts, :reply_to_id) == "msg_456"
    end

    test "includes thread_id when present" do
      target = MessagingTarget.for_thread("chat_123", "thread_456")

      opts = MessagingTarget.to_send_opts(target)

      assert Keyword.get(opts, :thread_id) == "thread_456"
    end

    test "includes reply_mode when not platform_default" do
      ctx = build_msg_context()
      target = MessagingTarget.for_reply(ctx, :inline)

      opts = MessagingTarget.to_send_opts(target)

      assert Keyword.get(opts, :reply_mode) == :inline
    end

    test "does not include reply_mode for platform_default" do
      ctx = build_msg_context()
      target = MessagingTarget.for_reply(ctx, :platform_default)

      opts = MessagingTarget.to_send_opts(target)

      refute Keyword.has_key?(opts, :reply_mode)
    end

    test "includes all applicable options" do
      target =
        MessagingTarget.for_thread("chat_123", "thread_456",
          reply_to_id: "msg_789",
          reply_to_mode: :thread
        )

      opts = MessagingTarget.to_send_opts(target)

      assert Keyword.get(opts, :reply_to_id) == "msg_789"
      assert Keyword.get(opts, :thread_id) == "thread_456"
      assert Keyword.get(opts, :reply_mode) == :thread
    end
  end

  defp build_msg_context(overrides \\ []) do
    incoming = %{
      external_room_id: "chat_123",
      external_user_id: "user_789",
      text: "Test message",
      external_message_id: "msg_456",
      chat_type: Keyword.get(overrides, :chat_type, :direct),
      external_thread_id: Keyword.get(overrides, :external_thread_id)
    }

    MsgContext.from_incoming(MockChannel, "instance_1", incoming)
  end
end
