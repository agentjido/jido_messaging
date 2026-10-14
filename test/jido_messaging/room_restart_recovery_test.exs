defmodule Jido.Messaging.RoomRestartRecoveryTest do
  use ExUnit.Case, async: true
  import Jido.Messaging.TestHelpers
  alias Jido.Chat.Room
  alias Jido.Messaging.{AgentRunner, RoomServer, RoomSupervisor}

  defmodule Runtime do
    use Jido.Messaging, runtime_profile: :core
  end

  defmodule PartialRuntime do
  end

  test "room startup remains tracked when the agent supervisor is absent" do
    start_supervised!({Registry, keys: :unique, name: Module.concat(PartialRuntime, Registry.Rooms)}, id: :rooms)
    start_supervised!({Registry, keys: :unique, name: Module.concat(PartialRuntime, Registry.Agents)}, id: :agents)

    supervisor = Module.concat(PartialRuntime, :RoomSupervisor)
    start_supervised!({RoomSupervisor, name: supervisor, instance_module: PartialRuntime})
    room = Room.new(%{type: :group})

    assert {:ok, pid} = RoomSupervisor.start_room(PartialRuntime, room)
    assert RoomServer.get_state(pid).room == room
    assert Enum.any?(DynamicSupervisor.which_children(supervisor), fn {_, child, _, _} -> child == pid end)
  end

  test "automatic room restart restores state from the existing runner" do
    start_supervised!(Runtime)
    {:ok, room} = Runtime.create_room(%{type: :group})
    {:ok, thread} = Runtime.save_thread(%{room_id: room.id})
    spec = %{agent_id: "alpha", name: "Alpha", handler: fn _, _ -> :noreply end}
    assert {:ok, registered_spec} = Runtime.register_agent(room.id, spec)
    assert {:ok, _} = Runtime.assign_thread(room.id, thread.id, "alpha")
    runner = AgentRunner.whereis(Runtime, room.id, thread.id, "alpha")
    old_room = RoomServer.whereis(Runtime, room.id)
    monitor = Process.monitor(old_room)
    Process.exit(old_room, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_room, :killed}

    assert_eventually(
      fn ->
        case RoomServer.whereis(Runtime, room.id) do
          pid when is_pid(pid) and pid != old_room ->
            state = RoomServer.get_state(pid)

            state.registered_agents["alpha"] == registered_spec and
              state.thread_assignments[thread.id] == "alpha"

          _ ->
            false
        end
      end,
      timeout: 1_000
    )

    assert AgentRunner.whereis(Runtime, room.id, thread.id, "alpha") == runner
    assert Process.alive?(runner)
    assert {:ok, _} = Runtime.assign_thread(room.id, thread.id, "alpha")
  end

  test "automatic restoration does not wait for a busy runner" do
    start_supervised!(Runtime)
    {:ok, room} = Runtime.create_room(%{type: :group})
    {:ok, thread} = Runtime.save_thread(%{room_id: room.id})
    spec = %{agent_id: "alpha", name: "Alpha", handler: fn _, _ -> :noreply end}
    assert {:ok, registered_spec} = Runtime.register_agent(room.id, spec)
    assert {:ok, _} = Runtime.assign_thread(room.id, thread.id, "alpha")
    runner = AgentRunner.whereis(Runtime, room.id, thread.id, "alpha")
    :ok = :sys.suspend(runner)

    try do
      assert_restored_after_restart(room.id, thread.id, registered_spec)
      assert AgentRunner.whereis(Runtime, room.id, thread.id, "alpha") == runner
    after
      if Process.alive?(runner), do: :sys.resume(runner)
    end
  end

  test "an unavailable agent supervisor name does not break room restart or another room" do
    start_supervised!(Runtime)
    {:ok, room} = Runtime.create_room(%{type: :group})
    {:ok, thread} = Runtime.save_thread(%{room_id: room.id})
    spec = %{agent_id: "alpha", name: "Alpha", handler: fn _, _ -> :noreply end}
    assert {:ok, registered_spec} = Runtime.register_agent(room.id, spec)
    assert {:ok, _} = Runtime.assign_thread(room.id, thread.id, "alpha")
    {:ok, other_room} = Runtime.create_room(%{type: :group})
    assert {:ok, other_pid} = RoomSupervisor.get_or_start_room(Runtime, other_room)
    name = Module.concat(Runtime, :AgentSupervisor)
    agent_supervisor = Process.whereis(name)
    true = Process.unregister(name)

    try do
      new_room = assert_restored_after_restart(room.id, thread.id, registered_spec)
      assert Process.alive?(other_pid)
      assert RoomServer.whereis(Runtime, other_room.id) == other_pid

      assert Enum.any?(
               DynamicSupervisor.which_children(Module.concat(Runtime, :RoomSupervisor)),
               fn {_, child, _, _} -> child == new_room end
             )
    after
      if Process.alive?(agent_supervisor) and is_nil(Process.whereis(name)) do
        Process.register(agent_supervisor, name)
      end
    end
  end

  test "room restart does not restore a runner outside its agent supervisor" do
    start_supervised!(Runtime)
    {:ok, room} = Runtime.create_room(%{type: :group})
    {:ok, thread} = Runtime.save_thread(%{room_id: room.id})
    assert {:ok, old_room} = RoomSupervisor.get_or_start_room(Runtime, room)
    spec = %{agent_id: "outside", name: "Outside", handler: fn _, _ -> :noreply end}

    runner =
      start_supervised!(
        {AgentRunner,
         instance_module: Runtime, room_id: room.id, thread_id: thread.id, agent_id: "outside", agent_config: spec}
      )

    monitor = Process.monitor(old_room)
    Process.exit(old_room, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_room, :killed}

    assert_eventually(fn ->
      case RoomServer.whereis(Runtime, room.id) do
        pid when is_pid(pid) and pid != old_room -> true
        _ -> false
      end
    end)

    state = RoomServer.get_state(RoomServer.whereis(Runtime, room.id))
    assert state.registered_agents == %{}
    assert state.thread_assignments == %{}
    assert Process.alive?(runner)
  end

  defp assert_restored_after_restart(room_id, thread_id, registered_spec) do
    old_room = RoomServer.whereis(Runtime, room_id)
    monitor = Process.monitor(old_room)
    Process.exit(old_room, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_room, :killed}

    assert_eventually(
      fn ->
        case RoomServer.whereis(Runtime, room_id) do
          pid when is_pid(pid) and pid != old_room ->
            state = RoomServer.get_state(pid)
            state.registered_agents["alpha"] == registered_spec and state.thread_assignments[thread_id] == "alpha"

          _ ->
            false
        end
      end,
      timeout: 1_000
    )

    RoomServer.whereis(Runtime, room_id)
  end
end
