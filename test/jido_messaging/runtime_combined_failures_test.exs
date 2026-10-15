defmodule Jido.Messaging.RuntimeCombinedFailuresTest do
  use ExUnit.Case, async: false
  import Jido.Messaging.TestHelpers
  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.{BridgeConfig, BridgeServer, BridgeSupervisor, RequestStore, Runtime, Subscription}
  alias Jido.Messaging.OutboundGateway.{Admission, Partition}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: {:error, :unused}
    @impl true
    def capabilities, do: %{send_message: :native}
    @impl true
    def send_message(_room, text, opts) do
      Agent.update(opts[:counts], &Map.update(&1, text, 1, fn n -> n + 1 end))
      send(opts[:probe], {:effect, self(), text})
      if text == "held", do: receive(do: (:release -> :ok))
      {:ok, %{id: text}}
    end
  end

  setup do
    Application.put_env(Instance, :outbound_gateway,
      partition_count: 1,
      queue_capacity: 2,
      pressure_policy: [shed_action: :none, degraded_action: :none]
    )

    on_exit(fn -> Application.delete_env(Instance, :outbound_gateway) end)
    root = start_supervised!(Instance)
    counts = start_supervised!({Agent, fn -> %{} end})
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, _} = Runtime.ensure_binding(runtime, Adapter, "provider", probe: self(), counts: counts)
    [{RequestStore, store}] = :ets.lookup(Runtime.request_table(runtime), RequestStore)
    parent = self()
    consumer = spawn(fn -> consume(parent) end)
    on_exit(fn -> Process.exit(consumer, :kill) end)
    {:ok, subscription} = Subscription.ensure(Instance, consumer, "combined.probe", [])
    assert_eventually(fn -> is_pid(:sys.get_state(subscription).bus) end, timeout: 1_000)

    %{
      root: root,
      runtime: runtime,
      runtime_pid: Process.whereis(runtime),
      store: store,
      counts: counts,
      consumer: consumer,
      subscription: subscription,
      partition: Partition.whereis(Instance, 0)
    }
  end

  test "Bus and bridge recovery with a held handler, store loss, and an accepted caller timeout", context do
    {:ok, bridge} =
      BridgeSupervisor.start_bridge(Instance, BridgeConfig.new(%{id: "listener", adapter_module: Adapter}))

    publish("held-event")
    assert_receive {:handler_held, "held-event"}, 1_000
    first = Task.async(fn -> Partition.dispatch(Instance, 0, request("held")) end)
    assert_receive {:effect, provider, "held"}, 1_000
    {bus_id, old_bus} = stop_bus(context.root)
    old_registry = Process.whereis(Module.concat(Instance, Registry.Bridges))
    Process.exit(old_registry, :kill)
    later = Task.async(fn -> timed_dispatch(request("queued")) end)
    assert Task.await(later) == :caller_timeout
    assert {:ok, _, %{load: 2}} = Admission.snapshot(Instance, 0, context.partition)
    {:ok, %{worker: old_store}} = RequestStore.call(context.store, :stats)
    Process.exit(old_store, :kill)

    assert_eventually(
      fn ->
        case RequestStore.call(context.store, :stats) do
          {:ok, %{worker: worker}} -> worker != old_store
          _ -> false
        end
      end,
      timeout: 2_000
    )

    assert {:ok, new_bus} = Supervisor.restart_child(context.root, bus_id)
    assert new_bus != old_bus
    assert_eventually(fn -> :sys.get_state(context.subscription).bus == new_bus end, timeout: 2_000)

    assert_eventually(
      fn ->
        replacement = BridgeServer.whereis(Instance, "listener")
        is_pid(replacement) and replacement != bridge
      end,
      timeout: 2_000
    )

    assert Process.alive?(provider)
    assert Partition.whereis(Instance, 0) == context.partition
    send(provider, :release)
    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}}} = Task.await(first)
    assert_receive {:effect, _, "queued"}, 1_000

    assert_eventually(fn -> match?({:ok, _, %{load: 0}}, Admission.snapshot(Instance, 0, context.partition)) end,
      timeout: 1_000
    )

    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}}} =
             Partition.dispatch(Instance, 0, request("held"))

    assert {:ok, _} = Partition.dispatch(Instance, 0, request("queued"))
    assert Agent.get(context.counts, & &1) == %{"held" => 1, "queued" => 1}
    send(context.consumer, :release_handler)
    assert_receive {:handler_completed, "held-event"}, 1_000
    publish("future-event")
    assert_receive {:handler_completed, "future-event"}, 1_000
    refute_receive {:handler_completed, "held-event"}
    assert map_size(:sys.get_state(new_bus).subscriptions) == 1
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert Process.alive?(context.root)
  end

  test "registry replacement fences old work while an accepted queued caller has timed out", context do
    first =
      Task.async(fn ->
        try do
          Partition.dispatch(Instance, 0, request("held"))
        catch
          :exit, _ -> :partition_exit
        end
      end)

    assert_receive {:effect, worker, "held"}, 1_000
    old_permit = :sys.get_state(context.partition).active.permit
    later = Task.async(fn -> timed_dispatch(request("queued")) end)
    assert Task.await(later) == :caller_timeout
    {bus_id, _} = stop_bus(context.root)
    monitor = Process.monitor(worker)
    Process.exit(Process.whereis(Module.concat(Instance, Registry.Instances)), :kill)
    assert Task.await(first) == :partition_exit
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000

    assert_eventually(
      fn ->
        replacement = Partition.whereis(Instance, 0)

        is_pid(replacement) and replacement != context.partition and
          match?({:ok, _, %{load: 0}}, Admission.snapshot(Instance, 0, replacement))
      end,
      timeout: 3_000
    )

    replacement = Partition.whereis(Instance, 0)
    Admission.release(old_permit)
    assert {:ok, _, %{load: 0}} = Admission.snapshot(Instance, 0, replacement)

    assert {:error, %{reason: %Contract{code: :request_outcome_unknown}}} =
             Partition.dispatch(Instance, 0, request("held"))

    assert {:ok, _} = Partition.dispatch(Instance, 0, request("queued"))
    assert_receive {:effect, _, "queued"}, 1_000
    assert Agent.get(context.counts, & &1) == %{"held" => 1, "queued" => 1}
    assert {:ok, bus} = Supervisor.restart_child(context.root, bus_id)
    assert_eventually(fn -> :sys.get_state(context.subscription).bus == bus end, timeout: 2_000)
    publish("after-recovery")
    assert_receive {:handler_completed, "after-recovery"}, 1_000
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert Process.alive?(context.root)
    assert {:ok, _, %{load: 0}} = Admission.snapshot(Instance, 0, replacement)
  end

  defp request(text),
    do: %{
      operation: :send,
      channel: Adapter,
      bridge_id: "provider",
      external_room_id: "room",
      payload: text,
      opts: [request_id: text],
      priority: :high,
      routing_key: "provider:room",
      max_attempts: 3
    }

  defp timed_dispatch(request) do
    try do
      Partition.dispatch(Instance, 0, request, 500)
    catch
      :exit, {:timeout, _} -> :caller_timeout
    end
  end

  defp stop_bus(root) do
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    {id, ^bus, _, _} = Enum.find(Supervisor.which_children(root), fn {_, pid, _, _} -> pid == bus end)
    :ok = Supervisor.terminate_child(root, id)
    {id, bus}
  end

  defp publish(id) do
    {:ok, signal} = Jido.Signal.new(%{id: id, type: "combined.probe", source: "combined", data: %{}})
    assert {:ok, _} = Jido.Signal.Bus.publish(Instance.signal_bus_name(), [signal])
  end

  defp consume(parent) do
    receive do
      {:signal, %{id: id}} ->
        if id == "held-event" do
          send(parent, {:handler_held, id})

          receive do
            :release_handler -> :ok
          end
        end

        send(parent, {:handler_completed, id})

      _ ->
        :ok
    end

    consume(parent)
  end
end
