defmodule Jido.Messaging.InstanceLifecycleRuntimeTest do
  use ExUnit.Case, async: false

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.{BridgeServer, Instance, InstanceSupervisor}

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule DeterministicListenerWorker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      label = Keyword.fetch!(opts, :label)
      order_agent = Keyword.fetch!(opts, :order_agent)
      test_pid = Keyword.get(opts, :test_pid)

      Agent.update(order_agent, fn order -> order ++ [label] end)

      if is_pid(test_pid) do
        send(test_pid, {:listener_started, label})
      end

      {:ok, opts}
    end
  end

  defmodule DeterministicChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "deterministic"}}

    @impl true
    def listener_child_specs(bridge_id, opts) do
      settings = Keyword.fetch!(opts, :settings)
      order_agent = setting(settings, :order_agent)
      test_pid = setting(settings, :test_pid)

      if is_pid(test_pid) do
        send(test_pid, {:listener_opts, opts})
      end

      {:ok,
       [
         Supervisor.child_spec(
           {DeterministicListenerWorker, [label: :listener_a, order_agent: order_agent, test_pid: test_pid]},
           id: {:listener, bridge_id, :a}
         ),
         Supervisor.child_spec(
           {DeterministicListenerWorker, [label: :listener_b, order_agent: order_agent, test_pid: test_pid]},
           id: {:listener, bridge_id, :b}
         )
       ]}
    end

    defp setting(settings, key) when is_map(settings) do
      Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
    end
  end

  defmodule RecoverableProbeChannel do
    @behaviour Jido.Chat.Adapter
    @behaviour Jido.Messaging.Adapters.Heartbeat

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "recoverable"}}

    @impl true
    def listener_child_specs(_bridge_id, _opts), do: {:ok, []}

    @impl true
    def probe_interval_ms, do: 10

    @impl true
    def check_health(%Instance{} = instance) do
      settings = instance.settings || %{}
      health_agent = Map.get(settings, :health_agent) || Map.get(settings, "health_agent")

      if is_pid(health_agent) do
        Agent.get_and_update(health_agent, fn
          [next | rest] -> {next, rest}
          [] -> {:ok, []}
        end)
      else
        :ok
      end
    end
  end

  defmodule CrashLoopWorker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      crash_after_ms = Keyword.get(opts, :crash_after_ms, 0)
      Process.send_after(self(), :crash, crash_after_ms)
      {:ok, opts}
    end

    @impl true
    def handle_info(:crash, state) do
      {:stop, :boom, state}
    end
  end

  defmodule CrashLoopChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "crash_loop"}}

    @impl true
    def listener_child_specs(bridge_id, opts) do
      settings = Keyword.fetch!(opts, :settings)
      crash_after_ms = Map.get(settings, :crash_after_ms) || Map.get(settings, "crash_after_ms") || 0

      {:ok,
       [
         Supervisor.child_spec(
           {CrashLoopWorker, [crash_after_ms: crash_after_ms]},
           id: {:crash_loop_worker, bridge_id}
         )
       ]}
    end
  end

  defmodule IsolatedCrashWorker do
    use GenServer

    def start_link(opts) do
      instance_module = Keyword.fetch!(opts, :instance_module)
      instance_id = Keyword.fetch!(opts, :instance_id)
      name = via_tuple(instance_module, instance_id)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @spec whereis(module(), String.t()) :: pid() | nil
    def whereis(instance_module, instance_id) do
      case Registry.lookup(registry_name(instance_module), {:isolated_worker, instance_id}) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end

    @spec crash(module(), String.t()) :: :ok | {:error, :not_found}
    def crash(instance_module, instance_id) do
      case whereis(instance_module, instance_id) do
        nil ->
          {:error, :not_found}

        pid ->
          GenServer.cast(pid, :crash)
          :ok
      end
    end

    @impl true
    def init(opts) do
      {:ok, opts}
    end

    @impl true
    def handle_cast(:crash, state) do
      {:stop, :boom, state}
    end

    defp via_tuple(instance_module, instance_id) do
      {:via, Registry, {registry_name(instance_module), {:isolated_worker, instance_id}}}
    end

    defp registry_name(instance_module) do
      Module.concat(instance_module, Registry.Instances)
    end
  end

  defmodule IsolatedCrashChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "isolated"}}

    @impl true
    def listener_child_specs(bridge_id, opts) do
      instance_module = Keyword.fetch!(opts, :instance_module)

      {:ok,
       [
         Supervisor.child_spec(
           {IsolatedCrashWorker, [instance_module: instance_module, instance_id: bridge_id]},
           id: {:isolated_worker, bridge_id}
         )
       ]}
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "ST-OCM-002 lifecycle orchestration" do
    test "bridge startup resolves listener child specs deterministically and reports bridge status" do
      {:ok, order_agent} = Agent.start_link(fn -> [] end)

      {:ok, instance} =
        TestMessaging.start_instance(:internal, %{
          name: "Lifecycle Bot",
          settings: %{
            channel_module: DeterministicChannel,
            probe_interval_ms: 60_000
          }
        })

      {:ok, _bridge} =
        TestMessaging.put_bridge_config(%{
          id: "deterministic_bridge",
          adapter_module: DeterministicChannel,
          opts: %{
            order_agent: order_agent,
            test_pid: self()
          }
        })

      assert_receive {:listener_opts, listener_opts}, 1_000
      assert listener_opts[:bridge_id] == "deterministic_bridge"
      assert listener_opts[:instance_module] == TestMessaging
      assert is_tuple(listener_opts[:sink_mfa])

      assert_eventually(
        fn ->
          Agent.get(order_agent, & &1) == [:listener_a, :listener_b]
        end,
        timeout: 1_000
      )

      {:ok, snapshot} = TestMessaging.instance_health(instance.id)

      assert snapshot.child_health_summary.total_children == 2
      assert snapshot.child_health_summary.running_children == 2
      assert snapshot.child_health_summary.children[Jido.Messaging.InstanceServer] == :up
      assert snapshot.child_health_summary.children["{:instance_reconnect_worker, \"#{instance.id}\"}"] == :up

      assert {:ok, bridge_status} =
               TestMessaging.list_bridges()
               |> Enum.find(&(&1.bridge_id == "deterministic_bridge"))
               |> then(fn
                 nil -> {:error, :bridge_not_found}
                 status -> {:ok, status}
               end)

      assert bridge_status.adapter_module == DeterministicChannel
      assert bridge_status.enabled == true
      assert bridge_status.listener_count == 2
    end

    test "recoverable failures trigger bounded reconnect with telemetry" do
      {:ok, health_agent} = Agent.start_link(fn -> [{:error, :timeout}, {:error, :network_error}, :ok] end)

      telemetry_handler = "instance-lifecycle-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          telemetry_handler,
          [
            [:jido_messaging, :instance, :reconnect_scheduled],
            [:jido_messaging, :instance, :reconnect_attempt],
            [:jido_messaging, :instance, :reconnect_exhausted]
          ],
          fn event, measurements, metadata, pid ->
            send(pid, {:lifecycle_telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn ->
        :telemetry.detach(telemetry_handler)
      end)

      {:ok, instance} =
        InstanceSupervisor.start_instance(TestMessaging, :internal, %{
          name: "Reconnect Bot",
          settings: %{
            channel_module: RecoverableProbeChannel,
            health_agent: health_agent,
            max_reconnect_attempts: 4,
            reconnect_base_backoff_ms: 5,
            reconnect_max_backoff_ms: 10,
            reconnect_jitter_ratio: 0.0,
            probe_interval_ms: 10
          }
        })

      assert_eventually(
        fn ->
          {:ok, status} = InstanceSupervisor.instance_status(TestMessaging, instance.id)
          status.status == :connected and status.reconnect_attempt == 0
        end,
        timeout: 1_000
      )

      telemetry_events = drain_lifecycle_telemetry([])

      reconnect_scheduled =
        Enum.filter(telemetry_events, fn {event, _measurements, _metadata} ->
          event == [:jido_messaging, :instance, :reconnect_scheduled]
        end)

      reconnect_attempts =
        Enum.filter(telemetry_events, fn {event, _measurements, _metadata} ->
          event == [:jido_messaging, :instance, :reconnect_attempt]
        end)

      refute Enum.any?(telemetry_events, fn {event, _measurements, _metadata} ->
               event == [:jido_messaging, :instance, :reconnect_exhausted]
             end)

      assert length(reconnect_scheduled) >= 1
      assert length(reconnect_attempts) >= 1

      max_attempt =
        reconnect_attempts
        |> Enum.map(fn {_event, measurements, _metadata} -> measurements.attempt end)
        |> Enum.max()

      assert max_attempt <= 4
    end

    test "bridge crash loops restart within bridge supervision without tearing down instance supervision" do
      instance_supervisor_name = TestMessaging.__jido_messaging__(:instance_supervisor)
      instance_supervisor_pid = Process.whereis(instance_supervisor_name)
      assert is_pid(instance_supervisor_pid)

      {:ok, _bridge} =
        TestMessaging.put_bridge_config(%{
          id: "crash_loop_bridge",
          adapter_module: CrashLoopChannel,
          opts: %{crash_after_ms: 0}
        })

      assert_eventually(
        fn ->
          is_pid(BridgeServer.whereis(TestMessaging, "crash_loop_bridge"))
        end,
        timeout: 500
      )

      first_bridge_pid = BridgeServer.whereis(TestMessaging, "crash_loop_bridge")
      assert is_pid(first_bridge_pid)
      bridge_ref = Process.monitor(first_bridge_pid)

      assert_receive {:DOWN, ^bridge_ref, :process, ^first_bridge_pid, _reason}, 2_000

      assert_eventually(
        fn ->
          restarted_bridge_pid = BridgeServer.whereis(TestMessaging, "crash_loop_bridge")
          is_pid(restarted_bridge_pid) and restarted_bridge_pid != first_bridge_pid
        end,
        timeout: 2_000
      )

      assert Process.alive?(instance_supervisor_pid)
    end

    test "worker crashes are isolated to the owning bridge subtree" do
      {:ok, _stable_bridge} =
        TestMessaging.put_bridge_config(%{
          id: "stable_bridge",
          adapter_module: DeterministicChannel,
          opts: %{order_agent: start_supervised!({Agent, fn -> [] end})}
        })

      {:ok, _crash_bridge} =
        TestMessaging.put_bridge_config(%{
          id: "crash_bridge",
          adapter_module: IsolatedCrashChannel,
          opts: %{}
        })

      assert_eventually(
        fn ->
          is_pid(BridgeServer.whereis(TestMessaging, "stable_bridge"))
        end,
        timeout: 500
      )

      stable_bridge_pid = BridgeServer.whereis(TestMessaging, "stable_bridge")
      stable_ref = Process.monitor(stable_bridge_pid)

      assert_eventually(
        fn ->
          is_pid(IsolatedCrashWorker.whereis(TestMessaging, "crash_bridge"))
        end,
        timeout: 500
      )

      crashed_worker = IsolatedCrashWorker.whereis(TestMessaging, "crash_bridge")
      crashed_ref = Process.monitor(crashed_worker)

      assert :ok = IsolatedCrashWorker.crash(TestMessaging, "crash_bridge")
      assert_receive {:DOWN, ^crashed_ref, :process, ^crashed_worker, :boom}, 500

      assert_eventually(
        fn ->
          restarted = IsolatedCrashWorker.whereis(TestMessaging, "crash_bridge")
          is_pid(restarted) and restarted != crashed_worker
        end,
        timeout: 500
      )

      refute_receive {:DOWN, ^stable_ref, :process, ^stable_bridge_pid, _reason}, 200
      assert Process.alive?(stable_bridge_pid)
    end
  end

  defp drain_lifecycle_telemetry(events) do
    receive do
      {:lifecycle_telemetry, event, measurements, metadata} ->
        drain_lifecycle_telemetry([{event, measurements, metadata} | events])
    after
      60 ->
        Enum.reverse(events)
    end
  end
end
