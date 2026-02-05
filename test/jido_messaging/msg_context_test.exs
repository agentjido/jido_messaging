defmodule JidoMessaging.MsgContextTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.MsgContext

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
      schema = MsgContext.schema()
      assert is_map(schema)
    end
  end

  describe "from_incoming/3" do
    test "creates MsgContext with required fields" do
      incoming = %{
        external_room_id: "chat_123",
        external_user_id: "user_456",
        text: "Hello world!"
      }

      ctx = MsgContext.from_incoming(MockChannel, "instance_1", incoming)

      assert ctx.channel_type == :mock
      assert ctx.channel_module == MockChannel
      assert ctx.instance_id == "instance_1"
      assert ctx.external_room_id == "chat_123"
      assert ctx.external_user_id == "user_456"
      assert ctx.body == "Hello world!"
      assert ctx.chat_type == :direct
    end

    test "handles all optional fields" do
      incoming = %{
        external_room_id: "chat_789",
        external_user_id: "user_123",
        text: "Test message",
        username: "testuser",
        display_name: "Test User",
        external_message_id: 12345,
        external_reply_to_id: 12344,
        external_thread_id: "thread_abc",
        timestamp: 1_706_745_600,
        chat_type: :group,
        was_mentioned: true,
        mentions: [%{user_id: "bot_1", offset: 0, length: 4}],
        channel_meta: %{custom: "data"},
        raw: %{original: "payload"}
      }

      ctx = MsgContext.from_incoming(MockChannel, "bot_1", incoming)

      assert ctx.sender_username == "testuser"
      assert ctx.sender_name == "Test User"
      assert ctx.external_message_id == "12345"
      assert ctx.external_reply_to_id == "12344"
      assert ctx.external_thread_id == "thread_abc"
      assert ctx.timestamp == 1_706_745_600
      assert ctx.chat_type == :group
      assert ctx.was_mentioned == true
      assert ctx.mentions == [%{user_id: "bot_1", offset: 0, length: 4}]
      assert ctx.channel_meta == %{custom: "data"}
      assert ctx.raw == %{original: "payload"}
    end

    test "converts integer instance_id to string" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: "Test"
      }

      ctx = MsgContext.from_incoming(MockChannel, 12345, incoming)
      assert ctx.instance_id == "12345"
    end

    test "converts integer external IDs to strings" do
      incoming = %{
        external_room_id: 999,
        external_user_id: 888,
        text: "Test",
        external_message_id: 777,
        external_reply_to_id: 666
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)
      assert ctx.external_room_id == "999"
      assert ctx.external_user_id == "888"
      assert ctx.external_message_id == "777"
      assert ctx.external_reply_to_id == "666"
    end

    test "maps chat types correctly" do
      chat_type_mappings = [
        {:private, :direct},
        {:group, :group},
        {:supergroup, :group},
        {:channel, :channel},
        {:thread, :thread},
        {:direct, :direct},
        {:unknown, :direct},
        {nil, :direct}
      ]

      for {input_type, expected_type} <- chat_type_mappings do
        incoming = %{
          external_room_id: "chat_#{input_type}",
          external_user_id: "user_1",
          text: "Test",
          chat_type: input_type
        }

        ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)
        assert ctx.chat_type == expected_type, "Expected #{expected_type} for input #{input_type}"
      end
    end

    test "handles nil text" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: nil
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)
      assert ctx.body == nil
    end
  end

  describe "with_resolved/4" do
    test "enriches context with resolved IDs" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: "Test"
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)

      room = %{id: "room_uuid_123"}
      participant = %{id: "participant_uuid_456"}
      message = %{id: "message_uuid_789", reply_to_id: "msg_prev", thread_root_id: "thread_root"}

      enriched = MsgContext.with_resolved(ctx, room, participant, message)

      assert enriched.room_id == "room_uuid_123"
      assert enriched.participant_id == "participant_uuid_456"
      assert enriched.message_id == "message_uuid_789"
      assert enriched.reply_to_id == "msg_prev"
      assert enriched.thread_root_id == "thread_root"

      # Original fields preserved
      assert enriched.external_room_id == "chat_1"
      assert enriched.external_user_id == "user_1"
      assert enriched.channel_type == :mock
    end
  end

  describe "to_legacy_context/1" do
    test "converts to legacy context map" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: "Test"
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)

      room = %{id: "room_1"}
      participant = %{id: "participant_1"}
      message = %{id: "msg_1", reply_to_id: nil, thread_root_id: nil}

      enriched = MsgContext.with_resolved(ctx, room, participant, message)
      legacy = MsgContext.to_legacy_context(enriched)

      assert legacy.room.id == "room_1"
      assert legacy.participant.id == "participant_1"
      assert legacy.channel == MockChannel
      assert legacy.instance_id == "inst"
      assert legacy.external_room_id == "chat_1"
    end
  end

  describe "defaults" do
    test "has sensible defaults for optional fields" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: "Test"
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)

      assert ctx.was_mentioned == false
      assert ctx.mentions == []
      assert ctx.channel_meta == %{}
      assert ctx.app_meta == %{}
      assert ctx.room_id == nil
      assert ctx.participant_id == nil
      assert ctx.message_id == nil
      assert ctx.command == nil
    end
  end

  describe "command field" do
    test "command defaults to nil" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: "/start arg1 arg2"
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)
      assert ctx.command == nil
    end

    test "command can be set after context creation" do
      incoming = %{
        external_room_id: "chat_1",
        external_user_id: "user_1",
        text: "/start arg1 arg2"
      }

      ctx = MsgContext.from_incoming(MockChannel, "inst", incoming)
      ctx_with_command = %{ctx | command: %{name: "start", args: "arg1 arg2"}}

      assert ctx_with_command.command == %{name: "start", args: "arg1 arg2"}
    end
  end
end
