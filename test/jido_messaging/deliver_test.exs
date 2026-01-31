defmodule JidoMessaging.DeliverTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.{Deliver, Ingest, Content.Text}

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
    def send_message(_chat_id, text, _opts) do
      if text == "fail_please" do
        {:error, :send_failed}
      else
        {:ok, %{message_id: 12345, chat_id: 789, date: 1_706_745_600}}
      end
    end
  end

  setup do
    start_supervised!(TestMessaging)

    incoming = %{
      external_room_id: "chat_deliver_test",
      external_user_id: "user_deliver_test",
      text: "Original message"
    }

    {:ok, original_message, context} =
      Ingest.ingest_incoming(TestMessaging, MockChannel, "deliver_inst", incoming)

    %{original_message: original_message, context: context}
  end

  describe "deliver_outgoing/5" do
    test "creates and sends reply message", %{original_message: orig, context: ctx} do
      assert {:ok, sent_message} =
               Deliver.deliver_outgoing(TestMessaging, orig, "Hello back!", ctx)

      assert sent_message.role == :assistant
      assert sent_message.room_id == orig.room_id
      assert sent_message.reply_to_id == orig.id
      assert sent_message.status == :sent
      assert [%Text{text: "Hello back!"}] = sent_message.content
      assert sent_message.metadata.external_message_id == 12345
    end

    test "returns error when channel send fails", %{original_message: orig, context: ctx} do
      assert {:error, :send_failed} =
               Deliver.deliver_outgoing(TestMessaging, orig, "fail_please", ctx)
    end

    test "message is persisted in room", %{original_message: orig, context: ctx} do
      {:ok, sent_message} = Deliver.deliver_outgoing(TestMessaging, orig, "Persisted reply", ctx)

      {:ok, messages} = TestMessaging.list_messages(orig.room_id)

      message_ids = Enum.map(messages, & &1.id)
      assert orig.id in message_ids
      assert sent_message.id in message_ids
    end
  end

  describe "send_to_room/5" do
    test "sends proactive message without reply_to", %{context: ctx, original_message: orig} do
      room_id = orig.room_id

      assert {:ok, sent_message} =
               Deliver.send_to_room(TestMessaging, room_id, "Proactive message!", ctx)

      assert sent_message.role == :assistant
      assert sent_message.room_id == room_id
      assert sent_message.reply_to_id == nil
      assert sent_message.status == :sent
      assert [%Text{text: "Proactive message!"}] = sent_message.content
    end
  end
end
