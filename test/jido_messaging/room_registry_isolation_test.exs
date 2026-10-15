defmodule Jido.Messaging.RoomRegistryIsolationTest do
  use ExUnit.Case, async: true
  import Jido.Messaging.TestHelpers
  alias Jido.Messaging.{DesiredWorkers, RequestLedger, RoomServer, RoomSupervisor, Runtime}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    root = start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    %{root: root, runtime: runtime, runtime_pid: Process.whereis(runtime), bus: bus}
  end

  test "registry loss restores 64 rooms and keeps unrelated groups and request history", context do
    rooms =
      for index <- 1..64 do
        {:ok, room} = Instance.create_room(%{id: "room-#{index}", name: "old", type: :group})
        {:ok, pid} = RoomSupervisor.start_room(Instance, room, message_limit: 7, timeout_ms: 12_345)
        {:ok, updated} = Instance.save_room(%{room | name: "saved"})
        {updated, pid}
      end

    unrelated = unrelated_pids()
    table = Runtime.request_table(context.runtime)
    {:ok, claim} = RequestLedger.claim(table, :retained, :payload, :authority)
    :ok = RequestLedger.complete(table, claim, {:original, %{value: 42}})
    kill_registry()

    assert_eventually(
      fn ->
        Enum.all?(rooms, fn {room, old} ->
          pid = RoomServer.whereis(Instance, room.id)
          is_pid(pid) and pid != old
        end)
      end,
      timeout: 3_000
    )

    for {room, _old} <- rooms do
      state = RoomServer.get_state(RoomServer.whereis(Instance, room.id))
      assert state.room == room
      assert state.message_limit == 7
      assert state.timeout_ms == 12_345
    end

    assert RequestLedger.claim(table, :retained, :payload, :authority) == {:cached, {:original, %{value: 42}}}
    assert {:error, %{code: :request_conflict}} = RequestLedger.claim(table, :retained, :changed, :authority)
    assert unrelated_pids() == unrelated
    assert_owners(context)
  end

  test "explicit stop removes only its desired room and duplicate starts keep options", context do
    {:ok, keep} = Instance.create_room(%{type: :group})
    {:ok, drop} = Instance.create_room(%{type: :group})
    {:ok, first} = RoomSupervisor.start_room(Instance, keep, message_limit: 7)
    assert {:ok, ^first} = RoomSupervisor.start_room(Instance, keep, message_limit: 99)
    {:ok, _} = RoomSupervisor.start_room(Instance, drop)
    assert :ok = RoomSupervisor.stop_room(Instance, drop.id)
    assert {:error, :not_found} = RoomSupervisor.stop_room(Instance, drop.id)
    kill_registry()
    assert_eventually(fn -> is_pid(RoomServer.whereis(Instance, keep.id)) end, timeout: 1_000)
    assert RoomSupervisor.count_rooms(Instance) == 1
    assert RoomServer.whereis(Instance, drop.id) == nil
    assert RoomServer.get_state(RoomServer.whereis(Instance, keep.id)).message_limit == 7
    assert_owners(context)
  end

  test "group downtime returns unavailable results and preserves desired starts", context do
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, _} = RoomSupervisor.start_room(Instance, room)
    id = Module.concat(Instance, Registry.Rooms)
    :ok = Supervisor.terminate_child(context.root, id)
    assert RoomServer.whereis(Instance, room.id) == nil
    assert RoomSupervisor.list_rooms(Instance) == []
    assert RoomSupervisor.count_rooms(Instance) == 0
    assert {:error, :not_found} = RoomSupervisor.stop_room(Instance, room.id)
    assert {:error, :supervisor_unavailable} = RoomSupervisor.start_room(Instance, room)
    assert {:ok, _} = Supervisor.restart_child(context.root, id)
    assert_eventually(fn -> is_pid(RoomServer.whereis(Instance, room.id)) end, timeout: 1_000)
    assert [{_, _}] = RoomSupervisor.list_rooms(Instance)
    assert_owners(context)
  end

  test "a stale external registration is not adopted or stopped", context do
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, owned} = RoomSupervisor.start_room(Instance, room)
    supervisor = Module.concat(Instance, :RoomSupervisor)
    :ok = DynamicSupervisor.terminate_child(supervisor, owned)
    {:ok, external} = RoomServer.start_link(room: room, instance_module: Instance)

    try do
      DesiredWorkers.restore(supervisor)

      assert_eventually(fn -> :sys.get_state(Module.concat(supervisor, :DesiredWorkers)).retry != nil end,
        timeout: 1_000
      )

      assert RoomServer.whereis(Instance, room.id) == external
      assert RoomSupervisor.count_rooms(Instance) == 0
    after
      GenServer.stop(external)
    end

    assert_eventually(fn -> RoomSupervisor.count_rooms(Instance) == 1 end, timeout: 1_000)
    assert_owners(context)
  end

  test "failed recovery keeps the specification until Runtime is available", context do
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, owned} = RoomSupervisor.start_room(Instance, room)
    supervisor = Module.concat(Instance, :RoomSupervisor)
    :ok = DynamicSupervisor.terminate_child(supervisor, owned)
    true = Process.unregister(context.runtime)

    try do
      DesiredWorkers.restore(supervisor)

      assert_eventually(fn -> :sys.get_state(Module.concat(supervisor, :DesiredWorkers)).retry != nil end,
        timeout: 1_000
      )

      assert RoomSupervisor.count_rooms(Instance) == 0
    after
      true = Process.register(context.runtime_pid, context.runtime)
    end

    assert_eventually(fn -> RoomSupervisor.count_rooms(Instance) == 1 end, timeout: 1_000)
    assert_owners(context)
  end

  test "rooms started without a saved record retain their supplied state", context do
    room = Jido.Chat.Room.new(%{type: :group, name: "unsaved"})
    {:ok, _} = RoomSupervisor.start_room(Instance, room)
    kill_registry()
    assert_eventually(fn -> is_pid(RoomServer.whereis(Instance, room.id)) end, timeout: 1_000)
    assert RoomServer.get_room(RoomServer.whereis(Instance, room.id)) == room
    assert_owners(context)
  end

  defp kill_registry do
    pid = Process.whereis(Module.concat(Instance, Registry.Rooms))
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp unrelated_pids do
    for suffix <- [
          Registry.Agents,
          Registry.Instances,
          :AgentSupervisor,
          :InstanceSupervisor,
          :SessionManagerSupervisor,
          :OutboundGatewaySupervisor,
          :DeadLetter,
          :ConfigStore,
          :Deduper
        ] do
      Process.whereis(Module.concat(Instance, suffix))
    end
  end

  defp assert_owners(context) do
    assert Process.whereis(context.runtime) == context.runtime_pid
    assert Jido.Signal.Bus.whereis(Instance.signal_bus_name()) == {:ok, context.bus}
    assert Process.alive?(context.root)
  end
end
