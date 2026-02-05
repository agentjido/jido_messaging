defmodule JidoMessaging.IngestTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Ingest

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  defmodule MockChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :mock

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: 999}}
  end

  setup do
    start_supervised!(TestMessaging)
    TestMessaging.clear_dedupe()
    :ok
  end

  describe "ingest_incoming/4" do
    test "creates room, participant, and message" do
      incoming = %{
        external_room_id: "chat_123",
        external_user_id: "user_456",
        text: "Hello world!",
        username: "testuser",
        display_name: "Test User",
        external_message_id: 789,
        timestamp: 1_706_745_600,
        chat_type: :private
      }

      assert {:ok, message, context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "instance_1", incoming)

      assert message.role == :user
      assert message.status == :sent
      assert [%JidoMessaging.Content.Text{text: "Hello world!"}] = message.content
      assert message.metadata.external_message_id == 789
      assert message.metadata.timestamp == 1_706_745_600

      assert context.room.id == message.room_id
      assert context.participant.id == message.sender_id
      assert context.channel == MockChannel
      assert context.instance_id == "instance_1"
      assert context.external_room_id == "chat_123"
      assert context.instance_module == TestMessaging
    end

    test "context includes instance_module for signal emission" do
      incoming = %{
        external_room_id: "chat_signal",
        external_user_id: "user_signal",
        text: "Signal test",
        external_message_id: 9999
      }

      {:ok, _message, context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "signal_inst", incoming)

      # instance_module is required for Signal.emit_received to find the Signal Bus
      assert context.instance_module == TestMessaging
      assert is_atom(context.instance_module)
    end

    test "reuses existing room for same external binding" do
      incoming = %{
        external_room_id: "chat_same",
        external_user_id: "user_1",
        text: "First message",
        external_message_id: 1001
      }

      {:ok, msg1, ctx1} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming)

      incoming2 = %{
        external_room_id: "chat_same",
        external_user_id: "user_2",
        text: "Second message",
        external_message_id: 1002
      }

      {:ok, msg2, ctx2} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming2)

      assert msg1.room_id == msg2.room_id
      assert ctx1.room.id == ctx2.room.id
    end

    test "reuses existing participant for same external user" do
      incoming1 = %{
        external_room_id: "chat_1",
        external_user_id: "same_user",
        text: "Message 1",
        external_message_id: 2001
      }

      {:ok, msg1, _ctx1} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming1)

      incoming2 = %{
        external_room_id: "chat_2",
        external_user_id: "same_user",
        text: "Message 2",
        external_message_id: 2002
      }

      {:ok, msg2, _ctx2} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming2)

      assert msg1.sender_id == msg2.sender_id
    end

    test "creates different rooms for different instances" do
      incoming_a = %{
        external_room_id: "chat_x",
        external_user_id: "user_x",
        text: "Test",
        external_message_id: 3001
      }

      incoming_b = %{
        external_room_id: "chat_x",
        external_user_id: "user_x",
        text: "Test",
        external_message_id: 3002
      }

      {:ok, msg1, _} = Ingest.ingest_incoming(TestMessaging, MockChannel, "instance_a", incoming_a)
      {:ok, msg2, _} = Ingest.ingest_incoming(TestMessaging, MockChannel, "instance_b", incoming_b)

      assert msg1.room_id != msg2.room_id
    end

    test "handles message without text" do
      incoming = %{
        external_room_id: "chat_no_text",
        external_user_id: "user_no_text",
        text: nil,
        external_message_id: 4001
      }

      {:ok, message, _context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming)

      assert message.content == []
    end

    test "maps chat types to room types correctly" do
      msg_id = 5000

      for {chat_type, expected_room_type} <- [
            {:private, :direct},
            {:group, :group},
            {:supergroup, :group},
            {:channel, :channel}
          ] do
        incoming = %{
          external_room_id: "chat_#{chat_type}",
          external_user_id: "user_type_test",
          text: "Test",
          chat_type: chat_type,
          external_message_id: msg_id + :erlang.phash2(chat_type)
        }

        {:ok, _msg, context} =
          Ingest.ingest_incoming(TestMessaging, MockChannel, "type_inst", incoming)

        assert context.room.type == expected_room_type,
               "Expected #{expected_room_type} for chat_type #{chat_type}"
      end
    end
  end
end
