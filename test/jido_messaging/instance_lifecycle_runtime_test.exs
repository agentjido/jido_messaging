defmodule JidoMessaging.InstanceLifecycleRuntimeTest do
  use ExUnit.Case, async: false

  import JidoMessaging.TestHelpers

  alias JidoMessaging.{Channel, Instance, InstanceServer, InstanceSupervisor}

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
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
    @behaviour Channel

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "deterministic"}}

    @impl true
    def listener_child_specs(instance_id, opts) do
      settings = Keyword.fetch!(opts, :settings)
      order_agent = setting(settings, :order_agent)
      test_pid = setting(settings, :test_pid)

      {:ok,
       [
         Supervisor.child_spec(
           {DeterministicListenerWorker, [label: :listener_a, order_agent: order_agent, test_pid: test_pid]},
           id: {:listener, instance_id, :a}
         ),
         Supervisor.child_spec(
           {DeterministicListenerWorker, [label: :listener_b, order_agent: order_agent, test_pid: test_pid]},
           id: {:listener, instance_id, :b}
         )
       ]}
    end

    defp setting(settings, key) when is_map(settings) do
      Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
    end
  end

  defmodule RecoverableProbeChannel do
    @behaviour Channel
    @behaviour JidoMessaging.Adapters.Heartbeat

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "recoverable"}}

    @impl true
    def listener_child_specs(_instance_id, _opts), do: {:ok, []}

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
    @behaviour Channel

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "crash_loop"}}

    @impl true
    def listener_child_specs(instance_id, opts) do
      settings = Keyword.fetch!(opts, :settings)
      crash_after_ms = Map.get(settings, :crash_after_ms) || Map.get(settings, "crash_after_ms") || 0

      {:ok,
       [
         Supervisor.child_spec(
           {CrashLoopWorker, [crash_after_ms: crash_after_ms]},
           id: {:crash_loop_worker, instance_id}
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
    @behaviour Channel

    @impl true
    def channel_type, do: :internal

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: "isolated"}}

    @impl true
    def listener_child_specs(instance_id, opts) do
      instance_module = Keyword.fetch!(opts, :instance_module)

      {:ok,
       [
         Supervisor.child_spec(
           {IsolatedCrashWorker, [instance_module: instance_module, instance_id: instance_id]},
           id: {:isolated_worker, instance_id}
         )
       ]}
    end
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "ST-OCM-002 lifecycle orchestration" do
    test "instance startup resolves listener child specs deterministically and reports health" do
      {:ok, order_agent} = Agent.start_link(fn -> [] end)

      {:ok, instance} =
        TestMessaging.start_instance(:internal, %{
          name: "Lifecycle Bot",
          settings: %{
            channel_module: DeterministicChannel,
            order_agent: order_agent,
            test_pid: self(),
            probe_interval_ms: 60_000
          }
        })

      assert_eventually(
        fn ->
          Agent.get(order_agent, & &1) == [:listener_a, :listener_b]
        end,
        timeout: 500
      )

      {:ok, snapshot} = TestMessaging.instance_health(instance.id)

      assert snapshot.child_health_summary.total_children == 4
      assert snapshot.child_health_summary.running_children == 4
      assert snapshot.child_health_summary.children[JidoMessaging.InstanceServer] == :up
      assert snapshot.child_health_summary.children["{:instance_reconnect_worker, \"#{instance.id}\"}"] == :up
      assert snapshot.child_health_summary.children["{:listener, \"#{instance.id}\", :a}"] == :up
      assert snapshot.child_health_summary.children["{:listener, \"#{instance.id}\", :b}"] == :up
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

    test "restart intensity escalation follows declared topology policy" do
      instance_supervisor_name = TestMessaging.__jido_messaging__(:instance_supervisor)
      old_instance_supervisor_pid = Process.whereis(instance_supervisor_name)
      assert is_pid(old_instance_supervisor_pid)

      ref = Process.monitor(old_instance_supervisor_pid)

      {:ok, _instance} =
        InstanceSupervisor.start_instance(TestMessaging, :internal, %{
          name: "Crash Loop Bot",
          settings: %{
            channel_module: CrashLoopChannel,
            crash_after_ms: 0,
            probe_interval_ms: 60_000
          }
        })

      assert_receive {:DOWN, ^ref, :process, ^old_instance_supervisor_pid, reason}, 5_000

      assert reason == :shutdown or
               String.contains?(inspect(reason), "reached_max_restart_intensity")

      assert_eventually(
        fn ->
          new_pid = Process.whereis(instance_supervisor_name)
          is_pid(new_pid) and new_pid != old_instance_supervisor_pid and Process.alive?(new_pid)
        end,
        timeout: 1_000
      )
    end

    test "worker crashes are isolated to the owning instance subtree" do
      {:ok, stable_order} = Agent.start_link(fn -> [] end)

      {:ok, stable_instance} =
        TestMessaging.start_instance(:internal, %{
          name: "Stable Bot",
          settings: %{
            channel_module: DeterministicChannel,
            order_agent: stable_order,
            probe_interval_ms: 60_000
          }
        })

      {:ok, crash_instance} =
        TestMessaging.start_instance(:internal, %{
          name: "Crash Bot",
          settings: %{
            channel_module: IsolatedCrashChannel,
            probe_interval_ms: 60_000
          }
        })

      stable_server = InstanceServer.whereis(TestMessaging, stable_instance.id)
      stable_ref = Process.monitor(stable_server)

      assert_eventually(
        fn ->
          is_pid(IsolatedCrashWorker.whereis(TestMessaging, crash_instance.id))
        end,
        timeout: 500
      )

      crashed_worker = IsolatedCrashWorker.whereis(TestMessaging, crash_instance.id)
      crashed_ref = Process.monitor(crashed_worker)

      assert :ok = IsolatedCrashWorker.crash(TestMessaging, crash_instance.id)
      assert_receive {:DOWN, ^crashed_ref, :process, ^crashed_worker, :boom}, 500

      assert_eventually(
        fn ->
          restarted = IsolatedCrashWorker.whereis(TestMessaging, crash_instance.id)
          is_pid(restarted) and restarted != crashed_worker
        end,
        timeout: 500
      )

      refute_receive {:DOWN, ^stable_ref, :process, ^stable_server, _reason}, 200
      assert Process.alive?(stable_server)
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
