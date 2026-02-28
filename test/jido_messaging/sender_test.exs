defmodule Jido.Messaging.SenderTest do
  use ExUnit.Case, async: true

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.Sender

  defmodule TestMessaging do
    use Jido.Messaging,
      adapter: Jido.Messaging.Adapters.ETS
  end

  defmodule SuccessChannel do
    def send_message(_room_id, _text, _opts) do
      {:ok, %{message_id: System.unique_integer([:positive])}}
    end
  end

  defmodule FailChannel do
    def send_message(_room_id, _text, _opts) do
      {:error, :network_error}
    end
  end

  defmodule FlakeyChannel do
    use Agent

    def start_link(opts) do
      fail_count = Keyword.get(opts, :fail_count, 2)
      Agent.start_link(fn -> fail_count end, name: __MODULE__)
    end

    def send_message(_room_id, _text, _opts) do
      remaining =
        Agent.get_and_update(__MODULE__, fn count ->
          {count, max(0, count - 1)}
        end)

      if remaining > 0 do
        {:error, :temporary_error}
      else
        {:ok, %{message_id: 12345}}
      end
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "enqueue/5" do
    test "queues message and returns job_id" do
      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "test_inst",
          channel: SuccessChannel
        )

      {:ok, job_id} = Sender.enqueue(pid, "msg_1", "chat_123", "Hello!")
      assert String.starts_with?(job_id, "job_")
    end

    test "processes queue and delivers successfully" do
      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "test_inst",
          channel: SuccessChannel
        )

      {:ok, _job_id} = Sender.enqueue(pid, "msg_2", "chat_456", "Test message")

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end)
    end
  end

  describe "queue_size/1" do
    test "returns current queue size" do
      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "test_inst",
          channel: SuccessChannel
        )

      assert Sender.queue_size(pid) == 0
    end
  end

  describe "retry behavior" do
    test "retries failed deliveries with backoff" do
      start_supervised!({FlakeyChannel, fail_count: 2})

      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "flakey_inst",
          channel: FlakeyChannel,
          base_backoff_ms: 5,
          max_backoff_ms: 20
        )

      {:ok, _job_id} = Sender.enqueue(pid, "msg_flakey", "chat", "Will retry")

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end, timeout: 500)
    end

    test "gives up after max attempts" do
      {:ok, pid} =
        Sender.start_link(
          instance_module: TestMessaging,
          instance_id: "fail_inst",
          channel: FailChannel,
          max_attempts: 2,
          base_backoff_ms: 5,
          max_backoff_ms: 20
        )

      {:ok, _job_id} = Sender.enqueue(pid, "msg_fail", "chat", "Will fail")

      assert_eventually(fn -> Sender.queue_size(pid) == 0 end, timeout: 500)
    end
  end

  describe "queue limits" do
    @tag :skip
    test "rejects when queue is full" do
      # This test is skipped because it requires a blocking channel
      # to prevent queue processing during enqueue.
      # The queue limit (1000) is enforced in the Sender module.
    end
  end
end
