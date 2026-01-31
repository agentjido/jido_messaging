defmodule JidoMessaging.SignalTest do
  # Not async because telemetry handlers can interfere across concurrent tests
  use ExUnit.Case, async: false

  alias JidoMessaging.{Signal, Ingest, Deliver}

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
        {:ok, %{message_id: 12345}}
      end
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "Signal.emit_received/2" do
    test "emits [:jido_messaging, :message, :received] event" do
      test_pid = self()
      handler_id = "test-received-handler-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :received],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      incoming = %{
        external_room_id: "chat_signal_test",
        external_user_id: "user_signal_test",
        text: "Hello signals!"
      }

      {:ok, message, context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "signal_inst", incoming)

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:jido_messaging, :message, :received]
      assert %DateTime{} = measurements.timestamp
      assert metadata.message.id == message.id
      assert metadata.room_id == message.room_id
      assert metadata.participant_id == message.sender_id
      assert metadata.channel == MockChannel
      assert metadata.instance_id == context.instance_id

      :telemetry.detach(handler_id)
    end
  end

  describe "Signal.emit_sent/2" do
    test "emits [:jido_messaging, :message, :sent] event on successful delivery" do
      test_pid = self()
      handler_id = "test-sent-handler-#{System.unique_integer()}"

      incoming = %{
        external_room_id: "chat_sent_test",
        external_user_id: "user_sent_test",
        text: "Original"
      }

      {:ok, original_message, context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "sent_inst", incoming)

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :sent],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:ok, sent_message} =
        Deliver.deliver_outgoing(TestMessaging, original_message, "Reply!", context)

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:jido_messaging, :message, :sent]
      assert %DateTime{} = measurements.timestamp
      assert metadata.message.id == sent_message.id
      assert metadata.room_id == sent_message.room_id
      assert metadata.channel == MockChannel
      assert metadata.external_room_id == context.external_room_id

      :telemetry.detach(handler_id)
    end

    test "emits [:jido_messaging, :message, :sent] event on send_to_room" do
      test_pid = self()
      handler_id = "test-sent-room-handler-#{System.unique_integer()}"

      incoming = %{
        external_room_id: "chat_room_test",
        external_user_id: "user_room_test",
        text: "Setup"
      }

      {:ok, original_message, context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "room_inst", incoming)

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :sent],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:ok, sent_message} =
        Deliver.send_to_room(TestMessaging, original_message.room_id, "Proactive!", context)

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:jido_messaging, :message, :sent]
      assert %DateTime{} = measurements.timestamp
      assert metadata.message.id == sent_message.id
      assert metadata.room_id == sent_message.room_id

      :telemetry.detach(handler_id)
    end
  end

  describe "Signal.emit_failed/3" do
    test "emits [:jido_messaging, :message, :failed] event on delivery failure" do
      test_pid = self()
      handler_id = "test-failed-handler-#{System.unique_integer()}"

      incoming = %{
        external_room_id: "chat_fail_test",
        external_user_id: "user_fail_test",
        text: "Original"
      }

      {:ok, original_message, context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "fail_inst", incoming)

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :failed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:error, :send_failed} =
        Deliver.deliver_outgoing(TestMessaging, original_message, "fail_please", context)

      assert_receive {:telemetry_event, event, measurements, metadata}

      assert event == [:jido_messaging, :message, :failed]
      assert %DateTime{} = measurements.timestamp
      assert metadata.room_id == original_message.room_id
      assert metadata.reason == :send_failed
      assert metadata.channel == MockChannel
      assert metadata.external_room_id == context.external_room_id

      :telemetry.detach(handler_id)
    end
  end

  describe "Signal module direct calls" do
    test "emit_received/2 executes telemetry" do
      test_pid = self()
      handler_id = "test-direct-received-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :received],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      message = %JidoMessaging.Message{
        id: "msg_test",
        room_id: "room_123",
        sender_id: "sender_456",
        role: :user,
        content: [],
        status: :sent,
        metadata: %{}
      }

      context = %{channel: MockChannel, instance_id: "inst_1"}

      Signal.emit_received(message, context)

      assert_receive {:telemetry_event, [:jido_messaging, :message, :received], _, metadata}
      assert metadata.message == message
      assert metadata.room_id == "room_123"
      assert metadata.participant_id == "sender_456"

      :telemetry.detach(handler_id)
    end

    test "emit_sent/2 executes telemetry" do
      test_pid = self()
      handler_id = "test-direct-sent-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :sent],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      message = %JidoMessaging.Message{
        id: "msg_sent",
        room_id: "room_789",
        sender_id: "system",
        role: :assistant,
        content: [],
        status: :sent,
        metadata: %{}
      }

      context = %{channel: MockChannel, external_room_id: "ext_room_1"}

      Signal.emit_sent(message, context)

      assert_receive {:telemetry_event, [:jido_messaging, :message, :sent], _, metadata}
      assert metadata.message == message
      assert metadata.room_id == "room_789"
      assert metadata.external_room_id == "ext_room_1"

      :telemetry.detach(handler_id)
    end

    test "emit_failed/3 executes telemetry" do
      test_pid = self()
      handler_id = "test-direct-failed-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :failed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      context = %{channel: MockChannel, external_room_id: "ext_room_fail"}

      Signal.emit_failed("room_fail", :timeout, context)

      assert_receive {:telemetry_event, [:jido_messaging, :message, :failed], _, metadata}
      assert metadata.room_id == "room_fail"
      assert metadata.reason == :timeout
      assert metadata.external_room_id == "ext_room_fail"

      :telemetry.detach(handler_id)
    end
  end
end
