defmodule Jido.Messaging.MsgContextTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{Message, MsgContext}

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

  describe "from_incoming/3" do
    test "builds the normalized envelope from adapter input" do
      ctx =
        MsgContext.from_incoming(MockChannel, 12345, %{
          external_room_id: 999,
          external_user_id: 888,
          text: "Hello world!",
          username: "testuser",
          display_name: "Test User",
          external_message_id: 777,
          external_reply_to_id: 666,
          external_thread_id: "thread_abc",
          delivery_external_room_id: "thread_room_abc",
          timestamp: 1_706_745_600,
          chat_type: :group,
          was_mentioned: true,
          mentions: [%{user_id: "bot_1", offset: 0, length: 4}],
          channel_meta: %{custom: "data"},
          raw: %{original: "payload"}
        })

      assert ctx.channel_type == :mock
      assert ctx.channel_module == MockChannel
      assert ctx.bridge_id == "12345"
      assert ctx.external_room_id == "999"
      assert ctx.external_user_id == "888"
      assert ctx.body == "Hello world!"
      assert ctx.sender_username == "testuser"
      assert ctx.sender_name == "Test User"
      assert ctx.external_message_id == "777"
      assert ctx.external_reply_to_id == "666"
      assert ctx.external_thread_id == "thread_abc"
      assert ctx.delivery_external_room_id == "thread_room_abc"
      assert ctx.timestamp == 1_706_745_600
      assert ctx.chat_type == :group
      assert ctx.was_mentioned
      assert ctx.mentions == [%{user_id: "bot_1", offset: 0, length: 4}]
      assert ctx.channel_meta == %{custom: "data"}
      assert ctx.raw == %{original: "payload"}
    end

    test "maps platform chat types into runtime chat types" do
      mappings = [
        {:private, :direct},
        {:group, :group},
        {:supergroup, :group},
        {:channel, :channel},
        {:thread, :thread},
        {:direct, :direct},
        {:unknown, :direct},
        {nil, :direct}
      ]

      for {input_type, expected_type} <- mappings do
        ctx =
          MsgContext.from_incoming(MockChannel, "inst", %{
            external_room_id: "chat_#{inspect(input_type)}",
            external_user_id: "user_1",
            text: "Test",
            chat_type: input_type
          })

        assert ctx.chat_type == expected_type
      end
    end

    test "defaults delivery_external_room_id to the external room" do
      ctx =
        MsgContext.from_incoming(MockChannel, "inst", %{
          external_room_id: "chat_1",
          external_user_id: "user_1",
          text: "Test"
        })

      assert ctx.delivery_external_room_id == "chat_1"
      assert ctx.was_mentioned == false
      assert ctx.mentions == []
      assert ctx.agent_mentions == []
      assert ctx.channel_meta == %{}
      assert ctx.app_meta == %{}
      assert ctx.room_id == nil
      assert ctx.participant_id == nil
      assert ctx.message_id == nil
    end
  end

  describe "with_resolved/4" do
    test "enriches the envelope with internal ids and resolved thread routing" do
      ctx =
        MsgContext.from_incoming(MockChannel, "inst", %{
          external_room_id: "chat_1",
          external_user_id: "user_1",
          text: "Test"
        })

      message =
        Message.new(%{
          room_id: "room_uuid_123",
          sender_id: "participant_uuid_456",
          role: :user,
          content: [%{type: :text, text: "Test"}],
          reply_to_id: "msg_prev",
          thread_id: "thread_uuid_789",
          external_thread_id: "thread_ext_789",
          delivery_external_room_id: "thread_room_789"
        })

      enriched =
        MsgContext.with_resolved(
          ctx,
          %{id: "room_uuid_123"},
          %{id: "participant_uuid_456"},
          message
        )

      assert enriched.room_id == "room_uuid_123"
      assert enriched.participant_id == "participant_uuid_456"
      assert enriched.message_id == message.id
      assert enriched.reply_to_id == "msg_prev"
      assert enriched.thread_id == "thread_uuid_789"
      assert enriched.external_thread_id == "thread_ext_789"
      assert enriched.delivery_external_room_id == "thread_room_789"
    end
  end
end
