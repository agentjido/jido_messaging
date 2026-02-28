defmodule Jido.Messaging.OutboundGatewayTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.OutboundGateway

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule PartitionChannel do
    @behaviour Jido.Chat.Adapter

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
    @behaviour Jido.Chat.Adapter

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
    @behaviour Jido.Chat.Adapter

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

  defmodule SlackSanitizeChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :slack

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, _opts), do: {:ok, %{message_id: "#{room_id}:#{text}"}}
  end

  defmodule MediaChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :media_channel

    @impl true
    def capabilities, do: [:text, :image]

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, _opts), do: {:ok, %{message_id: "#{room_id}:#{text}"}}

    @impl true
    def edit_message(room_id, message_id, text, _opts), do: {:ok, %{message_id: "#{room_id}:#{message_id}:#{text}"}}

    @impl false
    def send_media(room_id, payload, _opts),
      do: {:ok, %{message_id: "#{room_id}:media:#{payload.kind}", payload: payload}}

    @impl false
    def edit_media(room_id, message_id, payload, _opts),
      do: {:ok, %{message_id: "#{room_id}:#{message_id}:media_edit:#{payload.kind}", payload: payload}}
  end

  defmodule SlowSecurityAdapter do
    @behaviour Jido.Messaging.Security

    @impl true
    def verify_sender(_channel_module, _incoming_message, _raw_payload, _opts), do: :ok

    @impl true
    def sanitize_outbound(_channel_module, outbound, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 200))
      {:ok, outbound <> "_slow"}
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
      bridge_id: "partition_inst"
    }

    room_ids = Enum.map(1..24, &"room-#{&1}")

    partition_ids =
      Enum.map(room_ids, fn room_id ->
        context = Map.put(base_context, :external_room_id, room_id)
        {:ok, result} = OutboundGateway.send_message(TestMessaging, context, "hello")

        assert result.partition ==
                 OutboundGateway.route_partition(TestMessaging, base_context.bridge_id, room_id)

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
      bridge_id: "pressure_inst",
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
      bridge_id: "retry_inst",
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
      bridge_id: "edit_inst",
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

  test "routes supported media payloads through gateway media operations" do
    start_messaging(partition_count: 2, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: MediaChannel,
      bridge_id: "media_inst",
      external_room_id: "media_room"
    }

    media_payload = %{kind: :image, url: "https://example.com/pic.png", media_type: "image/png", size_bytes: 64}

    assert {:ok, send_result} = OutboundGateway.send_media(TestMessaging, context, media_payload)
    assert send_result.operation == :send_media
    assert send_result.message_id == "media_room:media:image"
    assert send_result.media.count == 1
    assert send_result.media.fallback == false

    assert {:ok, edit_result} =
             OutboundGateway.edit_media(TestMessaging, context, "msg-1", media_payload)

    assert edit_result.operation == :edit_media
    assert edit_result.message_id == "media_room:msg-1:media_edit:image"
    assert edit_result.media.count == 1
  end

  test "applies deterministic media text fallback for unsupported channels when configured" do
    start_messaging(partition_count: 2, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: PartitionChannel,
      bridge_id: "media_fallback_inst",
      external_room_id: "media_fallback_room"
    }

    media_payload = %{
      kind: :image,
      url: "https://example.com/missing.png",
      media_type: "image/png",
      fallback_text: "media unavailable"
    }

    assert {:ok, result} =
             OutboundGateway.send_media(
               TestMessaging,
               context,
               media_payload,
               media_policy: [unsupported_policy: :fallback_text]
             )

    assert result.operation == :send_media
    assert result.message_id == "media_fallback_room:media unavailable"
    assert result.media.fallback == true
    assert result.media.fallback_mode == :text_send
  end

  test "rejects unsupported media deterministically when fallback policy is reject" do
    start_messaging(partition_count: 2, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: PartitionChannel,
      bridge_id: "media_reject_inst",
      external_room_id: "media_reject_room"
    }

    media_payload = %{kind: :image, url: "https://example.com/missing.png", media_type: "image/png"}

    assert {:error, outbound_error} = OutboundGateway.send_media(TestMessaging, context, media_payload)
    assert outbound_error.category == :terminal
    assert {:unsupported_media, :image, causes} = outbound_error.reason
    assert :missing_capability in causes
    assert :missing_send_media_callback in causes
  end

  test "enforces outbound media size limits via policy preflight" do
    start_messaging(partition_count: 2, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: MediaChannel,
      bridge_id: "media_limit_inst",
      external_room_id: "media_limit_room"
    }

    media_payload = %{kind: :image, url: "https://example.com/large.png", media_type: "image/png", size_bytes: 999}

    assert {:error, outbound_error} =
             OutboundGateway.send_media(
               TestMessaging,
               context,
               media_payload,
               media_policy: [max_item_bytes: 128]
             )

    assert outbound_error.category == :terminal
    assert outbound_error.reason == {:media_policy_denied, :max_item_bytes_exceeded}
  end

  test "applies deterministic per-channel outbound sanitization before dispatch" do
    start_messaging(partition_count: 2, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: SlackSanitizeChannel,
      bridge_id: "sanitize_inst",
      external_room_id: "sanitize_room"
    }

    outbound = "hello @here\r\n<!channel>\x00"

    assert {:ok, result} = OutboundGateway.send_message(TestMessaging, context, outbound)
    assert result.message_id == "sanitize_room:hello @ here\n<! channel>"
    assert result.security.sanitize.decision.stage == :sanitize
    assert result.security.sanitize.metadata.channel_rule == :neutralize_mass_mentions
    assert result.security.sanitize.metadata.changed == true
  end

  test "sanitize timeout deny policy returns typed security reason with retryable classification" do
    start_messaging(partition_count: 1, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: PartitionChannel,
      bridge_id: "sanitize_timeout_deny_inst",
      external_room_id: "sanitize_timeout_deny_room"
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, outbound_error} =
             OutboundGateway.send_message(
               TestMessaging,
               context,
               "payload",
               security: [
                 adapter: SlowSecurityAdapter,
                 adapter_opts: [sleep_ms: 200],
                 sanitize_timeout_ms: 25,
                 sanitize_failure_policy: :deny
               ]
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert outbound_error.reason ==
             {:security_denied, :sanitize, {:security_failure, :retry}, "Security sanitize timed out"}

    assert outbound_error.category == :retryable
    assert elapsed_ms < 150
  end

  test "sanitize timeout allow_original policy keeps outbound flow moving" do
    start_messaging(partition_count: 1, queue_capacity: 8, max_attempts: 1)

    context = %{
      channel: PartitionChannel,
      bridge_id: "sanitize_timeout_allow_inst",
      external_room_id: "sanitize_timeout_allow_room"
    }

    assert {:ok, result} =
             OutboundGateway.send_message(
               TestMessaging,
               context,
               "payload",
               security: [
                 adapter: SlowSecurityAdapter,
                 adapter_opts: [sleep_ms: 200],
                 sanitize_timeout_ms: 25,
                 sanitize_failure_policy: :allow_original
               ]
             )

    assert result.message_id == "sanitize_timeout_allow_room:payload"
    assert result.security.sanitize.decision.action == :allow_original
    assert result.security.sanitize.decision.outcome == :allow_original_fallback
    assert result.security.sanitize.metadata.fallback == true
  end

  test "applies per-bridge delivery policy defaults when request retry opts are omitted" do
    start_supervised!(RetryChannel)
    start_messaging(partition_count: 1, queue_capacity: 8, max_attempts: 5, base_backoff_ms: 1, max_backoff_ms: 1)

    {:ok, _bridge} =
      TestMessaging.put_bridge_config(%{
        id: "delivery_policy_bridge",
        adapter_module: RetryChannel,
        delivery_policy: %{max_attempts: 1, base_backoff_ms: 1, max_backoff_ms: 1}
      })

    context = %{
      channel: RetryChannel,
      bridge_id: "delivery_policy_bridge",
      external_room_id: "delivery_policy_room"
    }

    assert {:error, outbound_error} = OutboundGateway.send_message(TestMessaging, context, "always_fail")
    assert outbound_error.max_attempts == 1
    assert outbound_error.attempt == 1
  end

  defp start_messaging(opts) do
    Application.put_env(TestMessaging, :outbound_gateway, opts)
    start_supervised!(TestMessaging)
  end
end
