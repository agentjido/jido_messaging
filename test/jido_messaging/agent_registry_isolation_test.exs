defmodule Jido.Messaging.AgentRegistryIsolationTest do
  use ExUnit.Case, async: true
  import Jido.Messaging.TestHelpers
  alias Jido.Messaging.{AgentRunner, AgentSupervisor, DesiredWorkers, RoomServer, RoomSupervisor}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    root = start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, bus} = Jido.Signal.Bus.whereis(Instance.signal_bus_name())
    {:ok, room} = Instance.create_room(%{type: :group})
    observer = self()

    config = %{
      agent_id: "alpha",
      name: "Alpha",
      handler: fn message, _ ->
        send(observer, {:handled, message.id})
        :noreply
      end
    }

    {:ok, config} = Instance.register_agent(room.id, config)
    %{root: root, runtime: runtime, runtime_pid: Process.whereis(runtime), bus: bus, room: room, config: config}
  end

  test "registry loss restores handler configuration and future observations", context do
    assignments =
      for index <- 1..16 do
        {:ok, thread} = Instance.save_thread(%{room_id: context.room.id, id: "thread-#{index}"})
        {:ok, _} = Instance.assign_thread(context.room.id, thread.id, "alpha")
        {thread.id, AgentRunner.whereis(Instance, context.room.id, thread.id, "alpha")}
      end

    old_room = RoomServer.whereis(Instance, context.room.id)
    unrelated = unrelated_pids()
    kill_registry()

    assert_eventually(
      fn ->
        Enum.all?(assignments, fn {thread, old} ->
          pid = AgentRunner.whereis(Instance, context.room.id, thread, "alpha")
          is_pid(pid) and pid != old and AgentRunner.get_state(pid).subscribed
        end)
      end,
      timeout: 3_000
    )

    assert RoomServer.whereis(Instance, context.room.id) == old_room
    assert AgentSupervisor.count_agents(Instance) == 16
    assert length(AgentSupervisor.list_all_agents(Instance)) == 16

    for {thread, _old} <- assignments do
      runner = AgentRunner.whereis(Instance, context.room.id, thread, "alpha")
      assert AgentRunner.get_state(runner).agent_config == context.config
    end

    {thread, _} = hd(assignments)

    {:ok, message} =
      Instance.save_message(%{
        room_id: context.room.id,
        thread_id: thread,
        sender_id: "user",
        role: :user,
        content: [Jido.Chat.Content.Text.new("hello")]
      })

    :ok = RoomServer.add_message(old_room, message)
    assert_receive {:handled, id}, 1_000
    assert id == message.id
    refute_receive {:handled, _}, 0
    assert unrelated_pids() == unrelated
    assert_owners(context)
  end

  test "explicit stop and unassignment during downtime remove desired runners", context do
    {:ok, stopped} = Instance.save_thread(%{room_id: context.room.id})
    {:ok, unassigned} = Instance.save_thread(%{room_id: context.room.id})
    for thread <- [stopped, unassigned], do: Instance.assign_thread(context.room.id, thread.id, "alpha")
    assert :ok = AgentSupervisor.stop_agent(Instance, context.room.id, stopped.id, "alpha")
    id = Module.concat(Instance, Registry.Agents)
    :ok = Supervisor.terminate_child(context.root, id)
    assert {:ok, cleared} = Instance.unassign_thread(context.room.id, unassigned.id)
    assert cleared.assigned_agent_id == nil
    assert {:ok, saved} = Instance.get_thread(stopped.id)
    assert saved.assigned_agent_id == "alpha"
    assert {:ok, _} = Supervisor.restart_child(context.root, id)
    manager = Module.concat(Module.concat(Instance, :AgentSupervisor), :DesiredWorkers)
    assert :sys.get_state(manager).supervisor == Module.concat(Instance, :AgentSupervisor)
    assert AgentSupervisor.count_agents(Instance) == 0
    assert_owners(context)
  end

  test "room and agent groups restore assignments in either start order", context do
    {:ok, thread} = Instance.save_thread(%{room_id: context.room.id})
    {:ok, _} = Instance.assign_thread(context.room.id, thread.id, "alpha")
    rooms = Module.concat(Instance, Registry.Rooms)
    agents = Module.concat(Instance, Registry.Agents)

    for order <- [[rooms, agents], [agents, rooms]] do
      :ok = Supervisor.terminate_child(context.root, rooms)
      :ok = Supervisor.terminate_child(context.root, agents)
      for group <- order, do: assert({:ok, _} = Supervisor.restart_child(context.root, group))

      assert_eventually(
        fn ->
          room = RoomServer.whereis(Instance, context.room.id)
          runner = AgentRunner.whereis(Instance, context.room.id, thread.id, "alpha")

          is_pid(room) and is_pid(runner) and RoomServer.get_state(room).registered_agents["alpha"] == context.config and
            RoomServer.thread_assignment(room, thread.id) == "alpha"
        end,
        timeout: 3_000
      )

      assert AgentSupervisor.count_agents(Instance) == 1
      assert RoomSupervisor.count_rooms(Instance) == 1
    end

    assert_owners(context)
  end

  test "a stale runner outside its supervisor is not adopted", context do
    {:ok, thread} = Instance.save_thread(%{room_id: context.room.id})
    {:ok, owned} = AgentSupervisor.start_agent(Instance, context.room.id, thread.id, "alpha", context.config)
    supervisor = Module.concat(Instance, :AgentSupervisor)
    :ok = DynamicSupervisor.terminate_child(supervisor, owned)

    {:ok, external} =
      AgentRunner.start_link(
        instance_module: Instance,
        room_id: context.room.id,
        thread_id: thread.id,
        agent_id: "alpha",
        agent_config: context.config
      )

    try do
      DesiredWorkers.restore(supervisor)

      assert_eventually(fn -> :sys.get_state(Module.concat(supervisor, :DesiredWorkers)).retry != nil end,
        timeout: 1_000
      )

      assert AgentSupervisor.count_agents(Instance) == 0
      assert Process.alive?(external)
    after
      GenServer.stop(external)
    end

    assert_eventually(fn -> AgentSupervisor.count_agents(Instance) == 1 end, timeout: 1_000)
    assert_owners(context)
  end

  test "group downtime uses unavailable results and a failed start is not retained", context do
    supervisor = Module.concat(Instance, :AgentSupervisor)
    assert {:error, _} = AgentSupervisor.start_agent(Instance, context.room.id, "invalid", "bad", %{})
    id = Module.concat(Instance, Registry.Agents)
    :ok = Supervisor.terminate_child(context.root, id)
    assert AgentRunner.whereis(Instance, context.room.id, "invalid", "bad") == nil
    assert AgentSupervisor.list_all_agents(Instance) == []
    assert AgentSupervisor.count_agents(Instance) == 0

    assert {:error, {:supervisor_unavailable, _}} =
             AgentSupervisor.start_agent(Instance, context.room.id, "new", "alpha", context.config)

    assert {:error, :not_found} = AgentSupervisor.stop_agent(Instance, context.room.id, "invalid", "bad")
    assert {:ok, _} = Supervisor.restart_child(context.root, id)
    DesiredWorkers.restore(supervisor)
    assert :sys.get_state(Module.concat(supervisor, :DesiredWorkers)).retry == nil
    assert AgentSupervisor.count_agents(Instance) == 0
    assert_owners(context)
  end

  defp kill_registry do
    pid = Process.whereis(Module.concat(Instance, Registry.Agents))
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp unrelated_pids do
    for suffix <- [
          Registry.Rooms,
          Registry.Instances,
          :RoomSupervisor,
          :InstanceSupervisor,
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
