defmodule Jido.Messaging.ReplayRegistryIsolationTest do
  use ExUnit.Case, async: true
  import Jido.Messaging.TestHelpers
  alias Jido.Messaging.{DeadLetter, RequestLedger, Runtime}
  alias Jido.Messaging.DeadLetter.{ReplaySupervisor, ReplayWorker}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    Application.put_env(Instance, :dead_letter, replay_partitions: 64)
    on_exit(fn -> Application.delete_env(Instance, :dead_letter) end)
    root = start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    %{root: root, runtime: runtime, runtime_pid: Process.whereis(runtime), bus: bus}
  end

  test "registry loss restores 64 partitions and keeps dead letters and request outcomes", context do
    completed = capture("completed")
    running = capture("running")
    {:ok, :replay, _} = DeadLetter.prepare_replay(Instance, completed.id)
    {:ok, completed} = DeadLetter.complete_replay(Instance, completed.id, {:ok, %{id: "original"}})
    {:ok, :replay, running} = DeadLetter.prepare_replay(Instance, running.id)
    table = Runtime.request_table(context.runtime)
    {:ok, claim} = RequestLedger.claim(table, :completed, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, {:original, 42})
    unrelated = unrelated_pids()
    old = for partition <- 0..63, do: ReplayWorker.whereis(Instance, partition)
    kill_registry()

    assert_eventually(
      fn ->
        Enum.all?(Enum.with_index(old), fn {previous, partition} ->
          pid = ReplayWorker.whereis(Instance, partition)
          is_pid(pid) and pid != previous
        end)
      end,
      timeout: 3_000
    )

    assert {:ok, ^completed} = DeadLetter.get(Instance, completed.id)
    assert {:ok, :already_replayed, ^completed} = DeadLetter.prepare_replay(Instance, completed.id)
    assert {:ok, ^running} = DeadLetter.get(Instance, running.id)
    assert {:error, :replay_in_progress} = DeadLetter.prepare_replay(Instance, running.id)
    assert RequestLedger.claim(table, :completed, :payload, :authority) == {:cached, {:original, 42}}
    assert unrelated_pids() == unrelated
    assert_owners(context)
  end

  test "group shutdown rejects replay before changing the retained record", context do
    record = capture("down")
    :ok = Supervisor.terminate_child(context.root, ReplaySupervisor)
    assert ReplayWorker.whereis(Instance, 0) == nil
    assert {:error, :replay_unavailable} = DeadLetter.replay(Instance, record.id)
    assert {:ok, ^record} = DeadLetter.get(Instance, record.id)
    assert {:ok, _} = Supervisor.restart_child(context.root, ReplaySupervisor)
    assert is_pid(ReplayWorker.whereis(Instance, 0))
    assert_owners(context)
  end

  test "an external registry blocks startup without adoption or loss of Runtime", context do
    :ok = Supervisor.terminate_child(context.root, ReplaySupervisor)
    registry = DeadLetter.replay_registry_name(Instance)
    {:ok, external_registry} = Registry.start_link(keys: :unique, name: registry)
    {:ok, external_worker} = ReplayWorker.start_link(instance_module: Instance, partition: 0)

    try do
      assert {:error, _} = Supervisor.restart_child(context.root, ReplaySupervisor)
      assert ReplayWorker.whereis(Instance, 0) == external_worker
      assert Process.alive?(external_registry)
      assert_owners(context)
    after
      GenServer.stop(external_worker)
      Supervisor.stop(external_registry)
    end

    assert {:ok, _} = Supervisor.restart_child(context.root, ReplaySupervisor)
    for partition <- 0..63, do: assert(is_pid(ReplayWorker.whereis(Instance, partition)))
    assert_owners(context)
  end

  test "static worker stop and restart retain their supervisor contract", context do
    supervisor = Module.concat(Instance, :DeadLetterReplaySupervisor)

    {:workers, workers, :supervisor, _} =
      Enum.find(Supervisor.which_children(supervisor), fn {id, _, _, _} -> id == :workers end)

    child = {:dead_letter_replay_worker, 0}
    :ok = Supervisor.terminate_child(workers, child)
    assert ReplayWorker.whereis(Instance, 0) == nil
    assert is_pid(ReplayWorker.whereis(Instance, 1))
    assert {:ok, _} = Supervisor.restart_child(workers, child)
    assert is_pid(ReplayWorker.whereis(Instance, 0))
    assert_owners(context)
  end

  defp capture(id) do
    request = %{operation: :send, routing_key: id, session_key: id, opts: []}

    {:ok, record} =
      DeadLetter.capture_outbound_failure(Instance, request, %{reason: :timeout, attempt: 1, max_attempts: 1})

    record
  end

  defp kill_registry do
    pid = Process.whereis(DeadLetter.replay_registry_name(Instance))
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp unrelated_pids do
    for suffix <- [
          Registry.Rooms,
          Registry.Agents,
          Registry.Instances,
          Registry.Bridges,
          :RoomSupervisor,
          :AgentSupervisor,
          :OutboundGatewaySupervisor,
          :DeadLetter,
          :ConfigStore,
          :Deduper
        ],
        do: Process.whereis(Module.concat(Instance, suffix))
  end

  defp assert_owners(context) do
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert Jido.Signal.Bus.whereis(Instance.signal_bus_name()) == {:ok, context.bus}
    assert Process.alive?(context.root)
  end
end
