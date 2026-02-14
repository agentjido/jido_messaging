defmodule JidoMessaging.ResilienceOpsTest do
  use ExUnit.Case, async: false

  alias JidoMessaging.OutboundGateway
  alias JidoMessaging.OutboundGateway.Partition
  import JidoMessaging.TestHelpers

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  defmodule ReplayChannel do
    use Agent
    @behaviour JidoMessaging.Channel

    def start_link(_opts) do
      Agent.start_link(fn -> %{failures_left: 1, send_count: 0} end, name: __MODULE__)
    end

    def set_failures(failures_left) when is_integer(failures_left) and failures_left >= 0 do
      Agent.update(__MODULE__, fn state -> %{state | failures_left: failures_left} end)
    end

    def send_count do
      Agent.get(__MODULE__, & &1.send_count)
    end

    @impl true
    def channel_type, do: :replay_channel

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        next_count = state.send_count + 1

        if state.failures_left > 0 do
          {{:error, :send_failed}, %{state | failures_left: state.failures_left - 1, send_count: next_count}}
        else
          {{:ok, %{message_id: "#{room_id}:#{text}:#{next_count}"}}, %{state | send_count: next_count}}
        end
      end)
    end
  end

  defmodule SlowPressureChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :slow_pressure_channel

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, _opts) do
      Process.sleep(120)
      {:ok, %{message_id: "#{room_id}:#{text}"}}
    end
  end

  setup do
    original_gateway_config = Application.get_env(TestMessaging, :outbound_gateway)
    original_dead_letter_config = Application.get_env(TestMessaging, :dead_letter)

    on_exit(fn ->
      restore_env(TestMessaging, :outbound_gateway, original_gateway_config)
      restore_env(TestMessaging, :dead_letter, original_dead_letter_config)
    end)

    :ok
  end

  test "captures terminal outbound failures in dead-letter storage with diagnostics context" do
    start_supervised!(ReplayChannel)
    ReplayChannel.set_failures(1)
    start_messaging(partition_count: 1, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: ReplayChannel,
      instance_id: "dlq_capture_inst",
      external_room_id: "dlq_capture_room"
    }

    assert {:error, outbound_error} =
             OutboundGateway.send_message(TestMessaging, context, "boom", correlation_id: "corr-123")

    assert is_binary(outbound_error.dead_letter_id)
    assert {:ok, record} = TestMessaging.get_dead_letter(outbound_error.dead_letter_id)
    assert record.reason == :send_failed
    assert record.category == :terminal
    assert record.disposition == :terminal
    assert record.correlation_id == "corr-123"
    assert record.request[:payload] == "boom"
    assert record.replay.status == :never
    assert record.diagnostics.queue_capacity == 8
  end

  test "replay is idempotent and guarded against duplicate side effects" do
    start_supervised!(ReplayChannel)
    ReplayChannel.set_failures(1)
    start_messaging(partition_count: 1, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: ReplayChannel,
      instance_id: "dlq_replay_inst",
      external_room_id: "dlq_replay_room"
    }

    assert {:error, outbound_error} = OutboundGateway.send_message(TestMessaging, context, "retry-me")
    dead_letter_id = outbound_error.dead_letter_id
    ReplayChannel.set_failures(0)

    assert {:ok, replayed} = TestMessaging.replay_dead_letter(dead_letter_id)
    assert replayed.status == :replayed
    assert replayed.response.idempotent == false

    assert {:ok, already_replayed} = TestMessaging.replay_dead_letter(dead_letter_id)
    assert already_replayed.status == :already_replayed
    assert ReplayChannel.send_count() == 2

    assert {:ok, updated_record} = TestMessaging.get_dead_letter(dead_letter_id)
    assert updated_record.replay.status == :succeeded
    assert updated_record.replay.attempts == 1
  end

  test "pressure thresholds trigger throttle and load-shed actions with operational telemetry" do
    start_messaging(
      partition_count: 1,
      queue_capacity: 5,
      max_attempts: 1,
      pressure_policy: [
        warn_ratio: 0.20,
        degraded_ratio: 0.40,
        shed_ratio: 0.60,
        degraded_action: :throttle,
        degraded_throttle_ms: 10,
        shed_action: :drop_low,
        shed_drop_priorities: [:low]
      ]
    )

    test_pid = self()
    handler_id = "pressure-action-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:jido_messaging, :pressure, :action],
      fn _event, _measurements, metadata, _ ->
        send(test_pid, {:pressure_action, metadata.action, metadata.pressure_level, metadata.priority})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    context = %{
      channel: SlowPressureChannel,
      instance_id: "pressure_policy_inst",
      external_room_id: "pressure_policy_room"
    }

    tasks = [
      Task.async(fn -> OutboundGateway.send_message(TestMessaging, context, "one", priority: :normal) end),
      Task.async(fn -> OutboundGateway.send_message(TestMessaging, context, "two", priority: :normal) end),
      Task.async(fn -> OutboundGateway.send_message(TestMessaging, context, "three", priority: :normal) end)
    ]

    assert_receive {:pressure_action, :throttle, :degraded, :normal}, 500

    assert {:error, load_shed_error} =
             OutboundGateway.send_message(TestMessaging, context, "drop-me", priority: :low)

    assert load_shed_error.reason == :load_shed
    assert_receive {:pressure_action, :shed_drop, :shed, :low}, 500

    Enum.each(tasks, fn task ->
      assert {:ok, _response} = Task.await(task, 1_000)
    end)
  end

  test "replay and pressure workers recover after crashes under supervision" do
    start_supervised!(ReplayChannel)
    ReplayChannel.set_failures(1)

    start_messaging(
      partition_count: 1,
      queue_capacity: 8,
      max_attempts: 1,
      dead_letter: [replay_partitions: 2, max_records: 100]
    )

    context = %{
      channel: ReplayChannel,
      instance_id: "crash_recovery_inst",
      external_room_id: "crash_recovery_room"
    }

    assert {:error, outbound_error} = OutboundGateway.send_message(TestMessaging, context, "crash-first")
    dead_letter_id = outbound_error.dead_letter_id

    replay_partition = JidoMessaging.DeadLetter.ReplayWorker.route_partition(TestMessaging, dead_letter_id)
    replay_worker = JidoMessaging.DeadLetter.ReplayWorker.whereis(TestMessaging, replay_partition)
    assert is_pid(replay_worker)

    Process.exit(replay_worker, :kill)

    assert_eventually(
      fn ->
        case JidoMessaging.DeadLetter.ReplayWorker.whereis(TestMessaging, replay_partition) do
          nil -> false
          pid -> is_pid(pid) and pid != replay_worker
        end
      end,
      timeout: 1_000
    )

    ReplayChannel.set_failures(0)
    assert {:ok, replayed} = TestMessaging.replay_dead_letter(dead_letter_id)
    assert replayed.status == :replayed

    outbound_partition = Partition.whereis(TestMessaging, 0)
    assert is_pid(outbound_partition)
    Process.exit(outbound_partition, :kill)

    assert_eventually(
      fn ->
        case Partition.whereis(TestMessaging, 0) do
          nil -> false
          pid -> is_pid(pid) and pid != outbound_partition
        end
      end,
      timeout: 1_000
    )

    assert {:ok, _response} = OutboundGateway.send_message(TestMessaging, context, "post-restart")
  end

  defp start_messaging(gateway_opts) do
    {dead_letter_opts, gateway_opts} = Keyword.pop(gateway_opts, :dead_letter, [])
    Application.put_env(TestMessaging, :outbound_gateway, gateway_opts)
    Application.put_env(TestMessaging, :dead_letter, dead_letter_opts)
    start_supervised!(TestMessaging)
  end

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
end
