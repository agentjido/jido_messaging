defmodule Jido.Messaging.OnboardingRegistryIsolationTest do
  use ExUnit.Case, async: true
  import Jido.Messaging.TestHelpers
  alias Jido.Messaging.{DesiredWorkers, RequestLedger, Runtime}
  alias Jido.Messaging.Onboarding.{Supervisor, Worker}

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule Core do
    use Jido.Messaging, runtime_profile: :core
  end

  defmodule Feature do
    use Jido.Messaging, runtime_profile: :core, runtime_features: [:onboarding]
  end

  defmodule Unknown do
    use Jido.Messaging, runtime_profile: :other
  end

  setup do
    root = start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    %{root: root, runtime: runtime, runtime_pid: Process.whereis(runtime), bus: bus}
  end

  test "registry loss restores saved flows and preserves transition idempotency", context do
    flows =
      for index <- 1..16 do
        id = "flow-#{index}"
        {:ok, _} = Instance.start_onboarding(%{onboarding_id: id, requester: index})
        {:ok, %{flow: flow}} = Instance.advance_onboarding(id, :resolve_directory, %{match_id: id}, idempotency_key: id)
        {id, Instance.whereis_onboarding_worker(id), flow}
      end

    table = Runtime.request_table(context.runtime)
    {:ok, claim} = RequestLedger.claim(table, :completed, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, {:original, 42})
    unrelated = unrelated_pids()
    kill_registry()

    assert_eventually(
      fn ->
        Enum.all?(flows, fn {id, previous, _} ->
          pid = Worker.whereis(Instance, id)
          is_pid(pid) and pid != previous
        end)
      end,
      timeout: 3_000
    )

    for {id, _previous, flow} <- flows do
      assert {:ok, ^flow} = Instance.resume_onboarding(id)

      assert {:ok, %{flow: ^flow, transition: %{idempotent: true}}} =
               Instance.advance_onboarding(id, :resolve_directory, %{match_id: id}, idempotency_key: id)
    end

    assert Supervisor.count_workers(Instance) == 16
    assert RequestLedger.claim(table, :completed, :payload, :authority) == {:cached, {:original, 42}}
    assert unrelated_pids() == unrelated
    assert_owners(context)
  end

  test "explicit stop and failed startup do not create recovery work", context do
    {:ok, _} = Instance.start_onboarding(%{onboarding_id: "stopped"})
    {:ok, _} = Instance.start_onboarding(%{onboarding_id: "kept"})
    assert {:error, :not_found} = Supervisor.start_worker(Instance, "missing")
    assert :ok = stop_worker("stopped")
    kill_registry()
    assert_eventually(fn -> is_pid(Worker.whereis(Instance, "kept")) end, timeout: 1_000)
    assert Worker.whereis(Instance, "stopped") == nil
    assert Worker.whereis(Instance, "missing") == nil
    assert Supervisor.count_workers(Instance) == 1
    assert_owners(context)
  end

  test "group downtime uses unavailable results and stop removes desired work", context do
    {:ok, _} = Instance.start_onboarding(%{onboarding_id: "down"})
    :ok = Elixir.Supervisor.terminate_child(context.root, registry())
    assert Worker.whereis(Instance, "down") == nil
    assert Supervisor.count_workers(Instance) == 0
    assert {:error, :worker_unavailable} = Instance.resume_onboarding("down")
    assert {:error, :not_found} = stop_worker("down")
    assert {:ok, _} = Elixir.Supervisor.restart_child(context.root, registry())
    assert Supervisor.count_workers(Instance) == 0
    assert {:ok, _} = Instance.resume_onboarding("down")
    assert Supervisor.count_workers(Instance) == 1
    assert_owners(context)
  end

  test "stale external worker is neither adopted nor stopped", context do
    {:ok, _} = Instance.start_onboarding(%{onboarding_id: "stale"})
    sup = Supervisor.supervisor_name(Instance)
    owned = Worker.whereis(Instance, "stale")
    :ok = DynamicSupervisor.terminate_child(sup, owned)
    {:ok, external} = Worker.start_link(instance_module: Instance, onboarding_id: "stale")

    try do
      DesiredWorkers.restore(sup)
      assert_eventually(fn -> :sys.get_state(Module.concat(sup, :DesiredWorkers)).retry != nil end, timeout: 1_000)
      assert Worker.whereis(Instance, "stale") == external
      assert Supervisor.count_workers(Instance) == 0
      assert Process.alive?(external)
    after
      GenServer.stop(external)
    end

    assert_eventually(fn -> is_pid(Worker.whereis(Instance, "stale")) end, timeout: 1_000)
    assert Supervisor.count_workers(Instance) == 1
    assert_owners(context)
  end

  test "restoration waits for Runtime availability", context do
    {:ok, _} = Instance.start_onboarding(%{onboarding_id: "runtime"})
    pid = Process.whereis(context.runtime)
    true = Process.unregister(context.runtime)

    try do
      kill_registry()
      manager = Module.concat(Supervisor.supervisor_name(Instance), :DesiredWorkers)
      assert_eventually(fn -> :sys.get_state(manager).retry != nil end, timeout: 1_000)
      assert Worker.whereis(Instance, "runtime") == nil
    after
      true = Process.register(pid, context.runtime)
    end

    assert_eventually(fn -> is_pid(Worker.whereis(Instance, "runtime")) end, timeout: 1_000)
    assert_owners(context)
  end

  test "existing runtime profiles select the optional group" do
    for module <- [Core, Feature, Unknown], do: start_supervised!(module)

    for module <- [Feature, Unknown] do
      assert is_pid(Process.whereis(Module.concat(module, Registry.Onboarding)))
      assert {:ok, _} = module.start_onboarding(%{onboarding_id: "profile"})
    end

    assert Process.whereis(Module.concat(Core, Registry.Onboarding)) == nil
    assert Process.whereis(Supervisor.supervisor_name(Core)) == nil
    assert Process.whereis(Module.concat(Supervisor.supervisor_name(Core), DesiredWorkers)) == nil
  end

  defp stop_worker(id),
    do: DesiredWorkers.stop(Instance, Supervisor.supervisor_name(Instance), id, fn -> Worker.whereis(Instance, id) end)

  defp registry, do: Module.concat(Instance, Registry.Onboarding)

  defp kill_registry do
    pid = Process.whereis(registry())
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
  end

  defp unrelated_pids do
    for suffix <- [Registry.Rooms, Registry.Agents, Registry.Instances, Registry.Bridges, :DeadLetter, :ConfigStore],
        do: Process.whereis(Module.concat(Instance, suffix))
  end

  defp assert_owners(context) do
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert Jido.Signal.Bus.whereis(Instance.signal_bus_name()) == {:ok, context.bus}
    assert Process.alive?(context.root)
  end
end
