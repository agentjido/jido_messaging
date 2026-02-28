defmodule Jido.Messaging.SessionManagerTest do
  use ExUnit.Case, async: false

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.{Ingest, OutboundGateway, SessionManager}

  defmodule TestMessaging do
    use Jido.Messaging,
      adapter: Jido.Messaging.Adapters.ETS
  end

  defmodule RoutingChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :routing

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(room_id, text, _opts), do: {:ok, %{message_id: "#{room_id}:#{text}"}}
  end

  setup do
    original_session_manager_config = Application.get_env(TestMessaging, :session_manager)
    original_outbound_gateway_config = Application.get_env(TestMessaging, :outbound_gateway)

    on_exit(fn ->
      restore_env(TestMessaging, :session_manager, original_session_manager_config)
      restore_env(TestMessaging, :outbound_gateway, original_outbound_gateway_config)
    end)

    :ok
  end

  test "partitions route state with deterministic hash resolution and hit telemetry" do
    start_messaging(
      session_manager: [partition_count: 4, ttl_ms: 5_000, max_entries_per_partition: 100, prune_interval_ms: 5_000],
      outbound_gateway: [partition_count: 2, queue_capacity: 8, max_attempts: 1]
    )

    test_pid = self()
    handler_id = "session-manager-hit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido_messaging, :session_route, :resolved],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:route_resolved, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    keys_and_routes =
      for room <- 1..8,
          thread_id <- [nil, "thread-#{room}"] do
        key = {:routing, "inst_partitioned", "room-#{room}", thread_id}

        route = %{
          channel_type: :routing,
          instance_id: "inst_partitioned",
          room_id: "room-#{room}",
          thread_id: thread_id,
          external_room_id: "ext-room-#{room}"
        }

        {key, route}
      end

    partition_ids =
      keys_and_routes
      |> Enum.map(fn {key, route} ->
        assert :ok = SessionManager.set(TestMessaging, key, route)
        assert {:ok, resolution} = SessionManager.resolve(TestMessaging, key, [route])
        assert resolution.source == :state_hit
        refute resolution.fallback
        refute resolution.stale
        SessionManager.route_partition(TestMessaging, key)
      end)

    partition_pids =
      keys_and_routes
      |> Enum.map(fn {key, _route} -> SessionManager.partition_pid(TestMessaging, key) end)
      |> Enum.uniq()

    assert partition_ids |> Enum.uniq() |> length() > 1
    assert partition_pids |> Enum.reject(&is_nil/1) |> length() > 1

    resolved_events = drain_route_resolved_events([])
    assert length(resolved_events) >= length(keys_and_routes)
    assert Enum.all?(resolved_events, &(&1.outcome in [:hit, :fallback]))
    assert Enum.any?(resolved_events, &(&1.outcome == :hit))
  end

  test "enforces TTL expiration and bounded eviction to prevent unbounded growth" do
    start_messaging(
      session_manager: [partition_count: 1, ttl_ms: 25, max_entries_per_partition: 2, prune_interval_ms: 5_000],
      outbound_gateway: [partition_count: 1, queue_capacity: 8, max_attempts: 1]
    )

    key_a = {:routing, "inst_ttl", "room-a", nil}
    key_b = {:routing, "inst_ttl", "room-b", nil}
    key_c = {:routing, "inst_ttl", "room-c", nil}

    route_a = %{external_room_id: "ext-room-a", room_id: "room-a"}
    route_b = %{external_room_id: "ext-room-b", room_id: "room-b"}
    route_c = %{external_room_id: "ext-room-c", room_id: "room-c"}

    assert :ok = SessionManager.set(TestMessaging, key_a, route_a)
    assert :ok = SessionManager.set(TestMessaging, key_b, route_b)
    assert :ok = SessionManager.set(TestMessaging, key_c, route_c)

    assert {:error, :not_found} = SessionManager.get(TestMessaging, key_a)
    assert {:ok, _record} = SessionManager.get(TestMessaging, key_b)
    assert {:ok, _record} = SessionManager.get(TestMessaging, key_c)

    Process.sleep(40)

    fallback_route = %{external_room_id: "fallback-room-b", room_id: "room-b"}
    assert {:ok, resolution} = SessionManager.resolve(TestMessaging, key_b, [fallback_route])
    assert resolution.source == :provided_fallback
    assert resolution.fallback
    assert resolution.stale
    assert resolution.fallback_reason == :stale
    assert resolution.external_room_id == "fallback-room-b"

    assert %{pruned: pruned_count, partitions: 1} = SessionManager.prune(TestMessaging)
    assert pruned_count >= 0
  end

  test "outbound resolution uses session route state and stale-route fallback telemetry" do
    start_messaging(
      session_manager: [partition_count: 2, ttl_ms: 200, max_entries_per_partition: 100, prune_interval_ms: 5_000],
      outbound_gateway: [partition_count: 2, queue_capacity: 16, max_attempts: 1]
    )

    test_pid = self()
    handler_id = "session-manager-fallback-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido_messaging, :session_route, :fallback],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:route_fallback, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    incoming = %{
      external_room_id: "primary-room",
      external_user_id: "routing-user",
      external_message_id: "primary-msg",
      text: "hello"
    }

    assert {:ok, _message, ingest_context} =
             Ingest.ingest_incoming(TestMessaging, RoutingChannel, "inst_outbound", incoming)

    session_key = {:routing, "inst_outbound", ingest_context.room.id, nil}
    assert {:ok, record} = SessionManager.get(TestMessaging, session_key)
    assert record.route.external_room_id == "primary-room"

    assert {:ok, preflight_resolution} =
             SessionManager.resolve(TestMessaging, session_key, [%{external_room_id: "fallback-room"}])

    assert preflight_resolution.source == :state_hit

    fresh_context = %{ingest_context | external_room_id: "fallback-room"}

    assert {:ok, fresh_result} = OutboundGateway.send_message(TestMessaging, fresh_context, "fresh-route")
    assert fresh_result.route_resolution.session_key == session_key
    assert fresh_result.message_id == "primary-room:fresh-route"
    assert fresh_result.route_resolution.source == :state_hit
    refute fresh_result.route_resolution.fallback

    Process.sleep(260)

    assert {:ok, stale_result} = OutboundGateway.send_message(TestMessaging, fresh_context, "stale-route")
    assert stale_result.message_id == "fallback-room:stale-route"
    assert stale_result.route_resolution.source == :provided_fallback
    assert stale_result.route_resolution.fallback
    assert stale_result.route_resolution.stale
    assert stale_result.route_resolution.fallback_reason == :stale

    assert_receive {:route_fallback, metadata}, 300
    assert metadata.reason == :stale
  end

  test "partition crashes recover via supervision without global routing outage" do
    start_messaging(
      session_manager: [partition_count: 2, ttl_ms: 5_000, max_entries_per_partition: 100, prune_interval_ms: 5_000],
      outbound_gateway: [partition_count: 2, queue_capacity: 8, max_attempts: 1]
    )

    {key_a, key_b} = distinct_partition_keys()

    route_a = %{external_room_id: "ext-recover-a", room_id: "room-recover-a"}
    route_b = %{external_room_id: "ext-recover-b", room_id: "room-recover-b"}

    assert :ok = SessionManager.set(TestMessaging, key_a, route_a)
    assert :ok = SessionManager.set(TestMessaging, key_b, route_b)

    partition_a = SessionManager.route_partition(TestMessaging, key_a)
    partition_b = SessionManager.route_partition(TestMessaging, key_b)
    assert partition_a != partition_b

    pid_a = SessionManager.partition_pid(TestMessaging, key_a)
    pid_b = SessionManager.partition_pid(TestMessaging, key_b)
    assert is_pid(pid_a)
    assert is_pid(pid_b)

    assert {:ok, resolution_b_before} = SessionManager.resolve(TestMessaging, key_b, [route_b])
    assert resolution_b_before.source == :state_hit

    ref = Process.monitor(pid_a)
    Process.exit(pid_a, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid_a, _reason}, 1_000

    assert_eventually(
      fn ->
        case SessionManager.partition_pid(TestMessaging, partition_a) do
          nil -> false
          new_pid -> is_pid(new_pid) and new_pid != pid_a
        end
      end,
      timeout: 1_000
    )

    assert Process.alive?(pid_b)

    assert {:ok, resolution_b_after} = SessionManager.resolve(TestMessaging, key_b, [route_b])
    assert resolution_b_after.source == :state_hit

    assert :ok = SessionManager.set(TestMessaging, key_a, route_a)
    assert {:ok, resolution_a_after} = SessionManager.resolve(TestMessaging, key_a, [route_a])
    assert resolution_a_after.external_room_id == "ext-recover-a"
  end

  defp start_messaging(opts) do
    session_manager_opts = Keyword.fetch!(opts, :session_manager)
    outbound_gateway_opts = Keyword.fetch!(opts, :outbound_gateway)

    Application.put_env(TestMessaging, :session_manager, session_manager_opts)
    Application.put_env(TestMessaging, :outbound_gateway, outbound_gateway_opts)

    start_supervised!(TestMessaging)
    TestMessaging.clear_dedupe()
  end

  defp distinct_partition_keys do
    keys =
      for index <- 1..40 do
        {:routing, "inst_recovery", "room-#{index}", nil}
      end

    grouped =
      Enum.group_by(keys, fn key ->
        SessionManager.route_partition(TestMessaging, key)
      end)

    partitions = Map.keys(grouped)

    if length(partitions) < 2 do
      raise "expected at least two session-manager partitions"
    end

    [partition_a, partition_b | _rest] = partitions
    [key_a | _] = Map.fetch!(grouped, partition_a)
    [key_b | _] = Map.fetch!(grouped, partition_b)
    {key_a, key_b}
  end

  defp drain_route_resolved_events(acc) do
    receive do
      {:route_resolved, metadata} -> drain_route_resolved_events([metadata | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
end
