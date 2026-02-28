defmodule Jido.Messaging.SenderIdempotencyTest do
  use ExUnit.Case, async: true

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.Sender

  defmodule TestMessaging do
    use Jido.Messaging,
      adapter: Jido.Messaging.Adapters.ETS
  end

  defmodule TrackingChannel do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def send_message(room_id, text, _opts) do
      message_id = System.unique_integer([:positive])

      Agent.update(__MODULE__, fn calls ->
        [{room_id, text, message_id} | calls]
      end)

      {:ok, %{message_id: message_id}}
    end

    def get_calls do
      Agent.get(__MODULE__, & &1)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> [] end)
    end
  end

  defmodule SlowTrackingChannel do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def send_message(room_id, text, _opts) do
      Process.sleep(10)
      message_id = System.unique_integer([:positive])

      Agent.update(__MODULE__, fn calls ->
        [{room_id, text, message_id} | calls]
      end)

      {:ok, %{message_id: message_id}}
    end

    def get_calls do
      Agent.get(__MODULE__, & &1)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> [] end)
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "has_been_sent?/2" do
    test "returns false for unsent message" do
      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_1",
          channel: TrackingChannel
        )

      refute Sender.has_been_sent?(pid, "msg_never_sent")
    end

    test "returns true after message is sent" do
      start_supervised!(TrackingChannel)
      TrackingChannel.reset()

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_2",
          channel: TrackingChannel
        )

      {:ok, _job_id} = Sender.enqueue(pid, "msg_to_send", "room", "Hello")

      assert_eventually(fn -> Sender.has_been_sent?(pid, "msg_to_send") end)
    end
  end

  describe "get_external_id/2" do
    test "returns :not_found for unsent message" do
      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_3",
          channel: TrackingChannel
        )

      assert Sender.get_external_id(pid, "msg_never_sent") == :not_found
    end

    test "returns external_message_id after send" do
      start_supervised!(TrackingChannel)
      TrackingChannel.reset()

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_4",
          channel: TrackingChannel
        )

      {:ok, _job_id} = Sender.enqueue(pid, "msg_get_ext", "room", "Hello")

      assert_eventually(fn -> Sender.has_been_sent?(pid, "msg_get_ext") end)

      {:ok, external_id} = Sender.get_external_id(pid, "msg_get_ext")
      assert is_integer(external_id)
    end
  end

  describe "duplicate detection" do
    test "duplicate enqueues don't result in duplicate sends" do
      start_supervised!(SlowTrackingChannel)
      SlowTrackingChannel.reset()

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_5",
          channel: SlowTrackingChannel
        )

      {:ok, _} = Sender.enqueue(pid, "dup_msg", "room", "Hello")
      {:ok, _} = Sender.enqueue(pid, "dup_msg", "room", "Hello")
      {:ok, _} = Sender.enqueue(pid, "dup_msg", "room", "Hello")

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end, timeout: 500)

      calls = SlowTrackingChannel.get_calls()
      assert length(calls) == 1
    end

    test "custom idempotency_key is used for deduplication" do
      start_supervised!(SlowTrackingChannel)
      SlowTrackingChannel.reset()

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_6",
          channel: SlowTrackingChannel
        )

      {:ok, _} = Sender.enqueue(pid, "msg_1", "room", "Hello", %{idempotency_key: "custom_key"})
      {:ok, _} = Sender.enqueue(pid, "msg_2", "room", "Hello", %{idempotency_key: "custom_key"})

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end, timeout: 500)

      calls = SlowTrackingChannel.get_calls()
      assert length(calls) == 1
    end

    test "different idempotency keys allow multiple sends" do
      start_supervised!(TrackingChannel)
      TrackingChannel.reset()

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_7",
          channel: TrackingChannel
        )

      {:ok, _} = Sender.enqueue(pid, "msg_a", "room", "Hello")
      {:ok, _} = Sender.enqueue(pid, "msg_b", "room", "Hello")
      {:ok, _} = Sender.enqueue(pid, "msg_c", "room", "Hello")

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end, timeout: 500)

      calls = TrackingChannel.get_calls()
      assert length(calls) == 3
    end
  end

  describe "cache size limiting" do
    test "LRU eviction when cache is full" do
      start_supervised!(TrackingChannel)
      TrackingChannel.reset()

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_8",
          channel: TrackingChannel,
          sent_cache_size: 3
        )

      {:ok, _} = Sender.enqueue(pid, "msg_1", "room", "Hello")
      assert_eventually(fn -> Sender.has_been_sent?(pid, "msg_1") end)

      {:ok, _} = Sender.enqueue(pid, "msg_2", "room", "Hello")
      assert_eventually(fn -> Sender.has_been_sent?(pid, "msg_2") end)

      {:ok, _} = Sender.enqueue(pid, "msg_3", "room", "Hello")
      assert_eventually(fn -> Sender.has_been_sent?(pid, "msg_3") end)

      assert Sender.has_been_sent?(pid, "msg_1")
      assert Sender.has_been_sent?(pid, "msg_2")
      assert Sender.has_been_sent?(pid, "msg_3")

      {:ok, _} = Sender.enqueue(pid, "msg_4", "room", "Hello")
      assert_eventually(fn -> Sender.has_been_sent?(pid, "msg_4") end)

      refute Sender.has_been_sent?(pid, "msg_1")
      assert Sender.has_been_sent?(pid, "msg_2")
      assert Sender.has_been_sent?(pid, "msg_3")
      assert Sender.has_been_sent?(pid, "msg_4")
    end
  end

  describe "skipped_duplicate telemetry" do
    test "emits skipped_duplicate signal when skipping already-sent message" do
      start_supervised!(SlowTrackingChannel)
      SlowTrackingChannel.reset()

      test_pid = self()

      :telemetry.attach(
        "test-skipped-duplicate",
        [:jido_messaging, :delivery, :skipped_duplicate],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "idem_test_9",
          channel: SlowTrackingChannel
        )

      {:ok, _} = Sender.enqueue(pid, "dup_signal_msg", "room", "Hello")
      {:ok, _} = Sender.enqueue(pid, "dup_signal_msg", "room", "Hello")

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end, timeout: 500)

      assert_receive {:telemetry_event, [:jido_messaging, :delivery, :skipped_duplicate], _measurements, metadata},
                     500

      assert metadata.message_id == "dup_signal_msg"
      assert metadata.idempotency_key == "dup_signal_msg"
      assert is_integer(metadata.external_message_id)

      :telemetry.detach("test-skipped-duplicate")
    end
  end
end
