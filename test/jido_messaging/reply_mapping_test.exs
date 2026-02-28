defmodule Jido.Messaging.ReplyMappingTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{Ingest, Deliver}

  defmodule TestMessaging do
    use Jido.Messaging,
      adapter: Jido.Messaging.Adapters.ETS
  end

  defmodule MockChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :mock

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, _text, _opts),
      do: {:ok, %{message_id: "ext_reply_#{System.unique_integer([:positive])}"}}
  end

  setup do
    start_supervised!(TestMessaging)
    TestMessaging.clear_dedupe()
    :ok
  end

  describe "external_id on message" do
    test "stores external_id when provided" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      message_attrs = %{
        room_id: room.id,
        sender_id: "user_1",
        role: :user,
        content: [],
        external_id: "ext_123",
        metadata: %{channel: :mock, bridge_id: "inst_1"}
      }

      {:ok, message} = TestMessaging.save_message(message_attrs)

      assert message.external_id == "ext_123"

      {:ok, fetched} = TestMessaging.get_message(message.id)
      assert fetched.external_id == "ext_123"
    end

    test "external_id is nil by default" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, message} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: []
        })

      assert message.external_id == nil
    end
  end

  describe "get_message_by_external_id/3" do
    test "finds message by external_id" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, message} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [],
          external_id: "ext_456",
          metadata: %{channel: :mock, bridge_id: "inst_1"}
        })

      {:ok, found} = TestMessaging.get_message_by_external_id(:mock, "inst_1", "ext_456")
      assert found.id == message.id
    end

    test "returns :not_found for unknown external_id" do
      assert {:error, :not_found} = TestMessaging.get_message_by_external_id(:mock, "inst_1", "nonexistent")
    end

    test "external_id lookup is scoped by channel and bridge_id" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, _} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [],
          external_id: "ext_scoped",
          metadata: %{channel: :mock, bridge_id: "inst_a"}
        })

      {:ok, found} = TestMessaging.get_message_by_external_id(:mock, "inst_a", "ext_scoped")
      assert found.external_id == "ext_scoped"

      assert {:error, :not_found} = TestMessaging.get_message_by_external_id(:mock, "inst_b", "ext_scoped")
      assert {:error, :not_found} = TestMessaging.get_message_by_external_id(:other_channel, "inst_a", "ext_scoped")
    end
  end

  describe "update_message_external_id/2" do
    test "updates external_id on existing message" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, message} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [],
          metadata: %{channel: :mock, bridge_id: "inst_1"}
        })

      assert message.external_id == nil

      {:ok, updated} = TestMessaging.update_message_external_id(message.id, "new_ext_id")
      assert updated.external_id == "new_ext_id"

      {:ok, fetched} = TestMessaging.get_message(message.id)
      assert fetched.external_id == "new_ext_id"
    end

    test "returns error for non-existent message" do
      assert {:error, :not_found} = TestMessaging.update_message_external_id("nonexistent_id", "ext_id")
    end
  end

  describe "reply_to resolution in ingest" do
    test "resolves external_reply_to_id to internal reply_to_id" do
      incoming_parent = %{
        external_room_id: "chat_reply_test",
        external_user_id: "user_1",
        text: "Parent message",
        external_message_id: "parent_ext_123"
      }

      {:ok, parent_msg, _ctx} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_reply", incoming_parent)

      assert parent_msg.external_id == "parent_ext_123"

      incoming_reply = %{
        external_room_id: "chat_reply_test",
        external_user_id: "user_2",
        text: "Reply message",
        external_message_id: "reply_ext_456",
        external_reply_to_id: "parent_ext_123"
      }

      {:ok, reply_msg, _ctx} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_reply", incoming_reply)

      assert reply_msg.reply_to_id == parent_msg.id
      assert reply_msg.external_id == "reply_ext_456"
    end

    test "reply_to_id is nil when external_reply_to_id cannot be resolved" do
      incoming = %{
        external_room_id: "chat_orphan",
        external_user_id: "user_1",
        text: "Orphan reply",
        external_message_id: "orphan_ext_789",
        external_reply_to_id: "nonexistent_parent"
      }

      {:ok, message, _ctx} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_orphan", incoming)

      assert message.reply_to_id == nil
    end

    test "reply_to_id is nil when no external_reply_to_id provided" do
      incoming = %{
        external_room_id: "chat_no_reply",
        external_user_id: "user_1",
        text: "No reply ref",
        external_message_id: "no_reply_ext"
      }

      {:ok, message, _ctx} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_no_reply", incoming)

      assert message.reply_to_id == nil
    end
  end

  describe "reply_to resolution in deliver" do
    test "deliver sets external_id from channel response" do
      incoming = %{
        external_room_id: "chat_deliver",
        external_user_id: "user_1",
        text: "Original message",
        external_message_id: "deliver_orig_ext"
      }

      {:ok, original_msg, context} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_deliver", incoming)

      {:ok, delivered_msg} = Deliver.deliver_outgoing(TestMessaging, original_msg, "Reply text", context)

      assert delivered_msg.status == :sent
      assert delivered_msg.external_id != nil
      assert String.starts_with?(delivered_msg.external_id, "ext_reply_")

      {:ok, persisted} = TestMessaging.get_message(delivered_msg.id)
      assert persisted.external_id == delivered_msg.external_id
    end

    test "deliver resolves reply_to_id to external_reply_to for channel" do
      incoming = %{
        external_room_id: "chat_ext_reply",
        external_user_id: "user_1",
        text: "LegacyMessage to reply to",
        external_message_id: "msg_to_reply_ext"
      }

      {:ok, original_msg, context} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_ext_reply", incoming)

      assert original_msg.external_id == "msg_to_reply_ext"

      {:ok, reply_msg} = Deliver.deliver_outgoing(TestMessaging, original_msg, "The reply", context)

      assert reply_msg.reply_to_id == original_msg.id
    end
  end

  describe "message metadata includes channel info" do
    test "ingest stores channel and bridge_id in metadata" do
      incoming = %{
        external_room_id: "chat_meta",
        external_user_id: "user_meta",
        text: "Metadata test",
        external_message_id: "meta_ext_123"
      }

      {:ok, message, _ctx} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst_meta", incoming)

      assert message.metadata[:channel] == :mock
      assert message.metadata[:bridge_id] == "inst_meta"
    end
  end
end
