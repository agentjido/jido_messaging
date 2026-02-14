defmodule JidoMessaging.OutboundGatewayTest do
  use ExUnit.Case, async: false

  alias JidoMessaging.OutboundGateway

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  defmodule PartitionChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :partition_channel

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, _opts), do: {:ok, %{message_id: "#{room_id}:#{text}"}}

    @impl true
    def edit_message(_room_id, message_id, text, _opts), do: {:ok, %{message_id: "#{message_id}:#{text}"}}
  end

  defmodule SlowChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :slow_channel

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, text, _opts) do
      Process.sleep(150)
      {:ok, %{message_id: "slow:#{text}"}}
    end
  end

  defmodule RetryChannel do
    use Agent
    @behaviour JidoMessaging.Channel

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    @impl true
    def channel_type, do: :retry_channel

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, text, _opts) do
      attempt =
        Agent.get_and_update(__MODULE__, fn attempts ->
          next_attempt = Map.get(attempts, text, 0) + 1
          {next_attempt, Map.put(attempts, text, next_attempt)}
        end)

      cond do
        text == "flaky" and attempt == 1 ->
          {:error, :network_error}

        text == "always_fail" ->
          {:error, :network_error}

        true ->
          {:ok, %{message_id: "#{text}:#{attempt}"}}
      end
    end
  end

  setup do
    original_config = Application.get_env(TestMessaging, :outbound_gateway)

    on_exit(fn ->
      if is_nil(original_config) do
        Application.delete_env(TestMessaging, :outbound_gateway)
      else
        Application.put_env(TestMessaging, :outbound_gateway, original_config)
      end
    end)

    :ok
  end

  test "distributes outbound work across partitions with stable routing metadata" do
    start_messaging(partition_count: 4, queue_capacity: 32, max_attempts: 1)

    base_context = %{
      channel: PartitionChannel,
      instance_id: "partition_inst"
    }

    room_ids = Enum.map(1..24, &"room-#{&1}")

    partition_ids =
      Enum.map(room_ids, fn room_id ->
        context = Map.put(base_context, :external_room_id, room_id)
        {:ok, result} = OutboundGateway.send_message(TestMessaging, context, "hello")

        assert result.partition ==
                 OutboundGateway.route_partition(TestMessaging, base_context.instance_id, room_id)

        assert result.operation == :send
        result.partition
      end)

    assert partition_ids |> Enum.uniq() |> length() > 1

    stable_context = Map.put(base_context, :external_room_id, "stable-room")

    {:ok, first} = OutboundGateway.send_message(TestMessaging, stable_context, "one")
    {:ok, second} = OutboundGateway.send_message(TestMessaging, stable_context, "two")

    assert first.partition == second.partition
  end

  test "enforces queue bounds and emits pressure transitions" do
    start_messaging(partition_count: 1, queue_capacity: 1, max_attempts: 1)

    test_pid = self()
    handler_id = "outbound-pressure-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:jido_messaging, :pressure, :transition],
      fn _event, _measurements, metadata, _ ->
        send(test_pid, {:pressure_transition, metadata.pressure_level, metadata.partition})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    context = %{
      channel: SlowChannel,
      instance_id: "pressure_inst",
      external_room_id: "pressure_room"
    }

    task_one = Task.async(fn -> OutboundGateway.send_message(TestMessaging, context, "first") end)
    Process.sleep(10)

    task_two = Task.async(fn -> OutboundGateway.send_message(TestMessaging, context, "second") end)

    assert Task.yield(task_two, 5) == nil

    assert {:error, queue_full_error} = OutboundGateway.send_message(TestMessaging, context, "third")
    assert queue_full_error.reason == :queue_full
    assert queue_full_error.category == :terminal

    assert_receive {:pressure_transition, :shed, 0}, 200

    assert {:ok, _result} = Task.await(task_one, 500)
    assert {:ok, _result} = Task.await(task_two, 500)
  end

  test "normalizes retryable failures and emits classification telemetry" do
    start_supervised!(RetryChannel)
    start_messaging(partition_count: 2, queue_capacity: 8, max_attempts: 2, base_backoff_ms: 1, max_backoff_ms: 1)

    test_pid = self()
    handler_id = "outbound-classification-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:jido_messaging, :outbound, :classified_error],
      fn _event, _measurements, metadata, _ ->
        send(test_pid, {:classified_error, metadata.category, metadata.reason, metadata.operation})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    context = %{
      channel: RetryChannel,
      instance_id: "retry_inst",
      external_room_id: "retry_room"
    }

    {:ok, flaky_result} = OutboundGateway.send_message(TestMessaging, context, "flaky")
    assert flaky_result.attempts == 2
    assert_receive {:classified_error, :retryable, :network_error, :send}, 200

    assert {:error, terminal_error} = OutboundGateway.send_message(TestMessaging, context, "always_fail")
    assert terminal_error.category == :retryable
    assert terminal_error.disposition == :terminal
    assert terminal_error.attempt == 2

    assert_receive {:classified_error, :retryable, :network_error, :send}, 200
  end

  test "supports edit operations and validates edit request contract" do
    start_messaging(partition_count: 3, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: PartitionChannel,
      instance_id: "edit_inst",
      external_room_id: "edit_room"
    }

    assert {:ok, edit_result} =
             OutboundGateway.edit_message(TestMessaging, context, "message-123", "updated")

    assert edit_result.operation == :edit
    assert edit_result.message_id == "message-123:updated"
    assert is_integer(edit_result.partition)

    assert {:error, invalid_edit} =
             OutboundGateway.edit_message(TestMessaging, context, nil, "updated")

    assert invalid_edit.reason == :missing_external_message_id
    assert invalid_edit.category == :terminal
  end

  defp start_messaging(opts) do
    Application.put_env(TestMessaging, :outbound_gateway, opts)
    start_supervised!(TestMessaging)
  end
end
