defmodule JidoMessaging.DeliverTest do
  use ExUnit.Case, async: false

  alias JidoMessaging.{Deliver, Ingest, Content.Image, Content.Text}

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

    @impl true
    def edit_message(_chat_id, _message_id, text, _opts) do
      if text == "fail_edit" do
        {:error, :edit_failed}
      else
        {:ok, %{message_id: 12345, edited: true}}
      end
    end
  end

  defmodule MediaChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :media_mock

    @impl true
    def capabilities, do: [:text, :image]

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, text, _opts), do: {:ok, %{message_id: "text:#{text}"}}

    @impl true
    def edit_message(_chat_id, message_id, text, _opts), do: {:ok, %{message_id: "#{message_id}:#{text}"}}

    @impl true
    def send_media(_chat_id, payload, _opts), do: {:ok, %{message_id: "media:#{payload.kind}", payload: payload}}

    @impl true
    def edit_media(_chat_id, message_id, payload, _opts),
      do: {:ok, %{message_id: "#{message_id}:media_edit:#{payload.kind}", payload: payload}}
  end

  defmodule SlowSecurityAdapter do
    @behaviour JidoMessaging.Security

    @impl true
    def verify_sender(_channel_module, _incoming_message, _raw_payload, _opts), do: :ok

    @impl true
    def sanitize_outbound(_channel_module, outbound, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 200))
      {:ok, outbound}
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
      assert sent_message.metadata.outbound_gateway.operation == :send
      assert is_integer(sent_message.metadata.outbound_gateway.partition)
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

    test "persists outbound security decision metadata", %{original_message: orig, context: ctx} do
      assert {:ok, sent_message} =
               Deliver.deliver_outgoing(TestMessaging, orig, "Hello secure outbound", ctx)

      assert is_map(sent_message.metadata.outbound_gateway.security)
      assert sent_message.metadata.outbound_gateway.security.sanitize.decision.stage == :sanitize
      assert sent_message.metadata.outbound_gateway.security.sanitize.decision.classification == :allow
    end

    test "returns typed security reason when sanitize timeout deny policy triggers", %{
      original_message: orig,
      context: ctx
    } do
      assert {:error, {:security_denied, :sanitize, {:security_failure, :retry}, "Security sanitize timed out"}} =
               Deliver.deliver_outgoing(TestMessaging, orig, "sanitize timeout", ctx,
                 security: [
                   adapter: SlowSecurityAdapter,
                   adapter_opts: [sleep_ms: 200],
                   sanitize_timeout_ms: 25,
                   sanitize_failure_policy: :deny
                 ]
               )
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
      assert sent_message.metadata.outbound_gateway.operation == :send
      assert is_integer(sent_message.metadata.outbound_gateway.partition)
    end
  end

  describe "edit_outgoing/5" do
    test "edits an existing outbound message through gateway", %{original_message: orig, context: ctx} do
      {:ok, sent_message} = Deliver.deliver_outgoing(TestMessaging, orig, "Initial", ctx)

      assert {:ok, edited_message} =
               Deliver.edit_outgoing(TestMessaging, sent_message, "Edited", ctx)

      assert [%Text{text: "Edited"}] = edited_message.content
      assert edited_message.metadata.outbound_gateway.operation == :edit
      assert is_integer(edited_message.metadata.outbound_gateway.partition)
    end

    test "returns error when attempting to edit without external id", %{original_message: orig, context: ctx} do
      {:ok, sent_message} = Deliver.deliver_outgoing(TestMessaging, orig, "Initial", ctx)
      no_external_id = %{sent_message | external_id: nil}

      assert {:error, :missing_external_message_id} =
               Deliver.edit_outgoing(TestMessaging, no_external_id, "Edited", ctx)
    end

    test "send and edit operations emit outbound gateway telemetry", %{original_message: orig, context: ctx} do
      test_pid = self()
      handler_id = "deliver-outbound-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :outbound, :completed],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:outbound_completed, metadata.operation, metadata.partition})
        end,
        nil
      )

      {:ok, sent_message} = Deliver.deliver_outgoing(TestMessaging, orig, "Initial", ctx)
      {:ok, _edited_message} = Deliver.edit_outgoing(TestMessaging, sent_message, "Edited", ctx)

      assert_receive {:outbound_completed, :send, partition}
      assert is_integer(partition)

      assert_receive {:outbound_completed, :edit, partition}
      assert is_integer(partition)

      :telemetry.detach(handler_id)
    end
  end

  describe "deliver_media_outgoing/5" do
    test "delivers media through outbound gateway and persists media metadata", %{
      original_message: orig,
      context: ctx
    } do
      media_payload = %{kind: :image, url: "https://example.com/photo.png", media_type: "image/png", size_bytes: 128}
      media_context = %{ctx | channel: MediaChannel}

      assert {:ok, sent_message} =
               Deliver.deliver_media_outgoing(TestMessaging, orig, media_payload, media_context)

      assert sent_message.status == :sent
      assert sent_message.metadata.outbound_gateway.operation == :send_media
      assert sent_message.metadata.outbound_gateway.media.count == 1
      assert sent_message.metadata.outbound_gateway.media.fallback == false
      assert sent_message.metadata.media.count == 1
      assert [%Image{url: "https://example.com/photo.png", media_type: "image/png"}] = sent_message.content
    end

    test "applies deterministic media fallback behavior when channel does not support media", %{
      original_message: orig,
      context: ctx
    } do
      media_payload = %{
        kind: :image,
        url: "https://example.com/unsupported.png",
        media_type: "image/png",
        fallback_text: "media fallback"
      }

      assert {:ok, sent_message} =
               Deliver.deliver_media_outgoing(TestMessaging, orig, media_payload, ctx,
                 media_policy: [unsupported_policy: :fallback_text]
               )

      assert sent_message.metadata.outbound_gateway.operation == :send_media
      assert sent_message.metadata.outbound_gateway.media.fallback == true
      assert sent_message.metadata.outbound_gateway.media.fallback_mode == :text_send
    end
  end
end
