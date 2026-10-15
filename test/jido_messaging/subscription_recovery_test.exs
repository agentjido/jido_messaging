defmodule Jido.Messaging.SubscriptionRecoveryTest do
  use ExUnit.Case, async: false

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.{AgentRunner, RequestLedger, Runtime, Subscription}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    supervisor = start_supervised!(Instance)
    parent = self()
    consumer = spawn(fn -> forward(parent) end)
    on_exit(fn -> Process.exit(consumer, :kill) end)
    %{supervisor: supervisor, consumer: consumer, bus: Instance.signal_bus_name()}
  end

  test "one worker owns one subscription and keeps the selector", %{consumer: consumer, bus: bus} do
    selector = [source: "subscription-test", subject: "room:one"]
    assert {:ok, worker} = Subscription.ensure(Instance, consumer, "subscription.probe", selector)
    assert {:ok, ^worker} = Subscription.ensure(Instance, consumer, "subscription.probe", selector)
    assert Subscription.current?(Instance, consumer, worker)
    refute Subscription.current?(Instance, consumer, self())
    refute Subscription.current?(__MODULE__, consumer, worker)
    assert_receive {:consumer, {:messaging_subscription_status, ^worker, true}}
    assert subscription_count(bus) == 1

    publish(bus, "allowed", "subscription-test", "room:one")
    assert_receive {:consumer, {:signal, %{id: "allowed"}}}
    publish(bus, "wrong-source", "other", "room:one")
    publish(bus, "wrong-room", "subscription-test", "room:other")
    refute_receive {:consumer, {:signal, _}}

    send(worker, {:subscription_signal, make_ref(), :stale})
    send(worker, {:retry, make_ref()})
    send(worker, {:DOWN, make_ref(), :process, self(), :stale})
    send(worker, :unrelated)
    assert :sys.get_state(worker).retry == nil
    refute_receive {:consumer, {:signal, :stale}}
  end

  test "sequential Bus restarts keep Runtime and request history", context do
    %{consumer: consumer, bus: bus} = context
    runtime = Instance.__jido_messaging__(:runtime)
    runtime_pid = Process.whereis(runtime)
    table = Runtime.request_table(runtime)
    {:ok, claim} = RequestLedger.claim(table, :completed, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, :exact_result)
    task = Task.async(fn -> RequestLedger.claim(table, :unknown, :payload, :authority) end)
    assert {:ok, _} = Task.await(task)

    {:ok, worker} = Subscription.ensure(Instance, consumer, "subscription.probe", [])
    assert_receive {:consumer, {:messaging_subscription_status, ^worker, true}}

    for index <- 1..3 do
      stop_bus(context)
      assert_receive {:consumer, {:messaging_subscription_status, ^worker, false}}
      assert :sys.get_state(worker).retry != nil
      restart_bus(context)
      assert_receive {:consumer, {:messaging_subscription_status, ^worker, true}}, 2_000
      assert subscription_count(bus) == 1
      id = "after-restart-#{index}"
      publish(bus, id)
      assert_receive {:consumer, {:signal, %{id: ^id}}}
      refute_receive {:consumer, {:signal, %{id: ^id}}}
      assert Process.whereis(runtime) == runtime_pid
      assert {:cached, :exact_result} = RequestLedger.claim(table, :completed, :payload, :authority)
      assert {:error, %{code: :request_outcome_unknown}} = RequestLedger.claim(table, :unknown, :payload, :authority)
    end
  end

  test "a killed worker replaces its old subscription", %{consumer: consumer, bus: bus} do
    {:ok, worker} = Subscription.ensure(Instance, consumer, "subscription.probe", [])
    assert_receive {:consumer, {:messaging_subscription_status, ^worker, true}}
    ref = Subscription.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:messaging_subscription_down, ^ref, :process, ^worker, :killed}
    assert_receive {:consumer, {:messaging_subscription_status, replacement, true}}, 1_000
    assert replacement != worker
    assert Subscription.current?(Instance, consumer, replacement)
    assert subscription_count(bus) == 1
    publish(bus, "after-worker-death")
    assert_receive {:consumer, {:signal, %{id: "after-worker-death"}}}
    refute_receive {:consumer, {:signal, %{id: "after-worker-death"}}}
  end

  test "consumer death removes its worker and subscription", %{consumer: consumer, bus: bus} do
    {:ok, worker} = Subscription.ensure(Instance, consumer, "subscription.probe", [])
    assert_receive {:consumer, {:messaging_subscription_status, ^worker, true}}
    monitor = Process.monitor(worker)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert subscription_count(bus) == 0
    refute Subscription.current?(Instance, consumer, worker)
  end

  test "consumer death during retry leaves no worker or timer", context do
    stop_bus(context)
    {:ok, worker} = Subscription.ensure(Instance, context.consumer, "subscription.probe", [])
    assert_eventually(fn -> :sys.get_state(worker).retry != nil end)
    monitor = Process.monitor(worker)
    Process.exit(context.consumer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 1_000
    assert reason in [:normal, :noproc]
    restart_bus(context)
    assert subscription_count(context.bus) == 0
    assert DynamicSupervisor.count_children(Module.concat(Instance, SubscriptionWorkers)).active == 0
  end

  test "failed subscribe retries without retaining a monitor", %{consumer: consumer, bus: bus} do
    {:ok, worker} = Subscription.ensure(Instance, consumer, "invalid..path", [])
    assert_eventually(fn -> :sys.get_state(worker).retry != nil end)
    state = :sys.get_state(worker)
    assert state.bus == nil
    assert state.bus_monitor == nil
    assert subscription_count(bus) == 0
    assert Process.alive?(worker)
  end

  test "retry delay is bounded and an old timer cannot reconnect", context do
    stop_bus(context)
    {:ok, worker} = Subscription.ensure(Instance, context.consumer, "subscription.probe", [])
    assert_eventually(fn -> :sys.get_state(worker).retry != nil end)

    for _ <- 1..5 do
      state = :sys.get_state(worker)
      {token, timer} = state.retry
      Process.cancel_timer(timer)
      send(worker, {:retry, token})
      assert_eventually(fn -> elem(:sys.get_state(worker).retry, 0) != token end)
    end

    assert :sys.get_state(worker).delay == 1_000
    restart_bus(context)
    assert_receive {:consumer, {:messaging_subscription_status, ^worker, true}}, 2_000
    assert :sys.get_state(worker).delay == 100
    assert subscription_count(context.bus) == 1
  end

  test "an unavailable worker supervisor returns an error", %{consumer: consumer} do
    assert {:error, :subscription_unavailable} = Subscription.ensure(__MODULE__, consumer, "subscription.probe", [])
  end

  test "AgentRunner restores a subscription while its handler is busy", context do
    observer = self()
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, thread} = Instance.save_thread(%{room_id: room.id})

    {:ok, _} =
      Instance.register_agent(room.id, %{
        agent_id: "recovery-agent",
        name: "RecoveryAgent",
        handler: fn message, _ ->
          send(observer, {:handler, self(), message.id})

          receive do
            :release -> :noreply
          end
        end
      })

    {:ok, _} = Instance.assign_thread(room.id, thread.id, "recovery-agent")
    runner = AgentRunner.whereis(Instance, room.id, thread.id, "recovery-agent")
    assert_eventually(fn -> AgentRunner.get_state(runner).subscribed end)
    first = save_message(room.id, thread.id, "first")
    {:ok, fact} = Jido.Messaging.Events.message_added(Instance, first)
    {:ok, _} = Jido.Signal.Bus.publish(context.bus, [fact])
    assert_receive {:handler, ^runner, first_id}
    assert first_id == first.id

    stop_bus(context)
    restart_bus(context)
    assert_eventually(fn -> subscription_count(context.bus) == 1 end, timeout: 2_000)
    second = save_message(room.id, thread.id, "second")
    {:ok, fact} = Jido.Messaging.Events.message_added(Instance, second)
    {:ok, _} = Jido.Signal.Bus.publish(context.bus, [fact])
    send(runner, :release)
    assert_receive {:handler, ^runner, second_id}, 1_000
    assert second_id == second.id
    send(runner, :release)
    assert AgentRunner.get_state(runner).subscribed
    send(runner, :subscribe)
    send(runner, {:messaging_subscription_status, self(), false})
    assert AgentRunner.get_state(runner).subscribed
    assert subscription_count(context.bus) == 1

    old_worker = subscription_worker(runner)
    Process.exit(old_worker, :kill)
    assert_eventually(fn -> subscription_worker(runner) not in [nil, old_worker] end)
    assert_eventually(fn -> AgentRunner.get_state(runner).subscribed end)
    assert subscription_count(context.bus) == 1
  end

  defp subscription_worker(consumer) do
    case Registry.lookup(Module.concat(Instance, Registry.Subscriptions), consumer) do
      [{worker, _}] -> worker
      [] -> nil
    end
  end

  defp save_message(room, thread, text) do
    {:ok, message} =
      Instance.save_message(%{
        room_id: room,
        thread_id: thread,
        sender_id: "user",
        role: :user,
        content: [%{type: :text, text: text}]
      })

    message
  end

  defp stop_bus(%{supervisor: supervisor, bus: bus}) do
    {:ok, pid} = Jido.Signal.Bus.whereis(bus)
    {id, ^pid, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, child, _, _} -> child == pid end)
    :ok = Supervisor.terminate_child(supervisor, id)
  end

  defp restart_bus(%{supervisor: supervisor}) do
    {id, :undefined, _, [Jido.Signal.Bus]} =
      Enum.find(Supervisor.which_children(supervisor), fn
        {_, :undefined, _, [Jido.Signal.Bus]} -> true
        _ -> false
      end)

    assert {:ok, _} = Supervisor.restart_child(supervisor, id)
  end

  defp subscription_count(bus) do
    {:ok, pid} = Jido.Signal.Bus.whereis(bus)
    map_size(:sys.get_state(pid).subscriptions)
  end

  defp publish(bus, id, source \\ "subscription-test", subject \\ nil) do
    {:ok, signal} = Jido.Signal.new(%{id: id, type: "subscription.probe", source: source, subject: subject, data: %{}})
    assert {:ok, _} = Jido.Signal.Bus.publish(bus, [signal])
  end

  defp forward(parent) do
    receive do
      message ->
        send(parent, {:consumer, message})
        forward(parent)
    end
  end
end
