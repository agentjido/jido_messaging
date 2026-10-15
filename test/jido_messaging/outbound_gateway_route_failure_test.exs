defmodule Jido.Messaging.OutboundGatewayRouteFailureTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Messaging.{OutboundGateway, Runtime, SessionManager}
  alias Jido.Messaging.OutboundGateway.Partition

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    for key <- [:outbound_gateway, :session_manager] do
      previous = Application.get_env(Instance, key)
      Application.put_env(Instance, key, partition_count: 1, max_attempts: 1)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(Instance, key),
          else: Application.put_env(Instance, key, previous)
      end)
    end

    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)

    context = %{
      channel: MockAdapter,
      channel_type: :test,
      bridge_id: "gateway-route",
      external_room_id: "provided-room"
    }

    {:ok, context: context, transport: transport}
  end

  test "fresh session state selects one provider room and preserves thread options", context do
    key = {:test, context.context.bridge_id, "canonical-room", "canonical-thread"}
    :ok = SessionManager.set(Instance, key, %{external_room_id: "selected-room"})

    target =
      Map.merge(context.context, %{
        room_id: "canonical-room",
        thread_id: "canonical-thread",
        external_thread_id: "provider-thread"
      })

    assert {:ok, result} = OutboundGateway.send_message(Instance, target, "complete text", transport: context.transport)
    assert result.route_resolution.source == :state_hit
    refute result.route_resolution.fallback
    assert result.route_resolution.session_key == key
    assert result.routing_key == "gateway-route:selected-room"

    assert [%{operation: :send_message, payload: %{room_id: "selected-room", text: "complete text", opts: opts}}] =
             MockTransport.calls(context.transport)

    assert opts[:thread_id] == "provider-thread"
  end

  test "an unloaded adapter uses its declared channel type before provider dispatch", context do
    adapter = Jido.Messaging.Test.ColdGatewayAdapter
    assert Code.ensure_loaded?(adapter)
    assert :code.delete(adapter)
    :code.purge(adapter)
    assert :code.is_loaded(adapter) == false
    on_exit(fn -> Code.ensure_loaded?(adapter) end)

    key = {:cold_gateway, context.context.bridge_id, "cold-room", nil}
    :ok = SessionManager.set(Instance, key, %{external_room_id: "cold-selected-room"})
    target = context.context |> Map.delete(:channel_type) |> Map.merge(%{channel: adapter, room_id: "cold-room"})

    assert {:ok, result} =
             OutboundGateway.send_message(Instance, target, "complete cold text", transport: context.transport)

    assert result.route_resolution.session_key == key
    assert result.route_resolution.source == :state_hit

    assert [%{payload: %{room_id: "cold-selected-room", text: "complete cold text"}}] =
             MockTransport.calls(context.transport)
  end

  test "nested canonical room uses the supplied delivery endpoint for a session miss", context do
    target = Map.merge(context.context, %{room: %{id: "nested-room"}, delivery_external_room_id: "delivery-room"})
    assert {:ok, result} = OutboundGateway.send_message(Instance, target, "hello", transport: context.transport)
    assert result.route_resolution.session_key == {:test, "gateway-route", "nested-room", nil}
    assert result.route_resolution.external_room_id == "delivery-room"
    assert result.route_resolution.fallback
    assert [%{payload: %{room_id: "delivery-room"}}] = MockTransport.calls(context.transport)
  end

  test "invalid channel type makes session resolution use the complete supplied route", context do
    target = Map.merge(context.context, %{channel_type: :unknown, channel: "invalid"})
    assert {:error, error} = OutboundGateway.send_message(Instance, target, "hello", transport: context.transport)
    assert error.reason == {:invalid_request, :channel}
    assert_no_provider_or_admission(context)
  end

  test "missing external room fails before adapter binding and callback", context do
    target = Map.delete(context.context, :external_room_id)
    assert {:error, error} = OutboundGateway.send_message(Instance, target, "hello", transport: context.transport)
    assert error.reason == {:invalid_request, :external_room_id}
    assert error.category == :terminal
    refute error.retryable
    assert_no_provider_or_admission(context)
  end

  test "missing media edit identity fails before adapter binding and callback", context do
    assert {:error, error} =
             OutboundGateway.edit_media(Instance, context.context, nil, %{kind: :image, bytes: "all bytes"},
               transport: context.transport
             )

    assert error.reason == :missing_external_message_id
    assert_no_provider_or_admission(context)
  end

  test "unavailable gateway partition has a fatal outcome without a provider call", context do
    supervisor = Module.concat(Instance, OutboundGatewaySupervisor)
    [{id, _pid, _kind, _modules}] = Supervisor.which_children(supervisor)
    :ok = Supervisor.terminate_child(supervisor, id)
    await_partition_removed()

    assert {:error, error} =
             OutboundGateway.send_message(Instance, context.context, "hello", transport: context.transport)

    assert error.reason == :partition_unavailable
    assert error.category == :fatal
    assert error.disposition == :terminal
    assert error.attempt == 1
    assert error.max_attempts == 1
    assert_no_provider_or_admission(context)
  end

  test "invalid gateway configuration retains valid queue and pressure bounds" do
    Application.put_env(Instance, :outbound_gateway,
      partition_count: 0,
      queue_capacity: -1,
      max_attempts: nil,
      base_backoff_ms: "invalid",
      max_backoff_ms: 0,
      sent_cache_size: false,
      pressure_policy: %{
        warn_ratio: 0.9,
        degraded_ratio: 0.2,
        shed_ratio: 0.1,
        degraded_action: :invalid,
        degraded_throttle_ms: -1,
        shed_action: :invalid,
        shed_drop_priorities: [:invalid]
      }
    )

    config = OutboundGateway.config(Instance)

    for key <- [:partition_count, :queue_capacity, :max_attempts, :base_backoff_ms, :max_backoff_ms, :sent_cache_size],
        do: assert(is_integer(config[key]) and config[key] > 0)

    pressure = config[:pressure_policy]
    assert pressure[:warn_ratio] < pressure[:degraded_ratio]
    assert pressure[:degraded_ratio] < pressure[:shed_ratio]
    assert pressure[:degraded_action] == :throttle
    assert pressure[:degraded_throttle_ms] == 0
    assert pressure[:shed_action] == :drop_low
    assert pressure[:shed_drop_priorities] == [:low]
  end

  defp assert_no_provider_or_admission(context) do
    assert MockTransport.calls(context.transport) == []
    runtime = Instance.__jido_messaging__(:runtime)
    assert Runtime.get_state(runtime).bindings == %{}
    assert Jido.Messaging.TestHelpers.runtime_entry_count(runtime) == 0
  end

  defp await_partition_removed(attempts \\ 1_000)
  defp await_partition_removed(0), do: flunk("stopped gateway partition remains registered")

  defp await_partition_removed(attempts) do
    if is_nil(Partition.whereis(Instance, 0)) do
      :ok
    else
      Process.sleep(1)
      await_partition_removed(attempts - 1)
    end
  end
end
