defmodule Jido.Messaging.AgentAssignmentRecoveryTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{AgentRunner, AgentSupervisor, RoomServer, RoomSupervisor, Runtime}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    :ok
  end

  test "explicit restoration starts only registered agents for persisted assignments in their own rooms" do
    rooms = for id <- ["owned", "other", "unregistered"], do: room(id)
    [owned, other, unregistered] = rooms
    for selected <- [owned, other], do: register(selected.id, "alpha")

    for selected <- rooms do
      assert {:ok, _} =
               Instance.save_thread(%{id: selected.id <> "-thread", room_id: selected.id, assigned_agent_id: "alpha"})
    end

    assert {:ok, unassigned} = Instance.save_thread(%{id: "unassigned", room_id: owned.id})

    assert {:ok, unknown} =
             Instance.save_thread(%{id: "unknown-agent", room_id: owned.id, assigned_agent_id: "unknown"})

    assert AgentSupervisor.count_agents(Instance) == 0
    assert :ok = Jido.Messaging.restore_agent_runners(Instance)
    owned_runner = AgentRunner.whereis(Instance, owned.id, "owned-thread", "alpha")
    other_runner = AgentRunner.whereis(Instance, other.id, "other-thread", "alpha")
    assert is_pid(owned_runner)
    assert is_pid(other_runner)
    assert owned_runner != other_runner
    assert AgentRunner.whereis(Instance, unregistered.id, "unregistered-thread", "alpha") == nil
    assert AgentRunner.whereis(Instance, owned.id, unassigned.id, "alpha") == nil
    assert AgentRunner.whereis(Instance, owned.id, unknown.id, "unknown") == nil
    assert AgentSupervisor.count_agents(Instance) == 2
    assert :ok = Jido.Messaging.restore_agent_runners(Instance)
    assert AgentRunner.whereis(Instance, owned.id, "owned-thread", "alpha") == owned_runner
    assert AgentRunner.whereis(Instance, other.id, "other-thread", "alpha") == other_runner
    assert_authority_empty()
  end

  test "unavailable agent supervisor leaves old assignment on unassign failure and permits later cleanup" do
    room = room("stop-failure")
    register(room.id, "alpha")
    assert {:ok, thread} = Instance.save_thread(%{id: "owned-thread", room_id: room.id})
    assert {:ok, assigned} = Instance.assign_thread(room.id, thread.id, "alpha")
    server = RoomServer.whereis(Instance, room.id)
    runner = AgentRunner.whereis(Instance, room.id, thread.id, "alpha")
    supervisor = Process.whereis(Instance.__jido_messaging__(:supervisor))
    agent_supervisor = Process.whereis(Instance.__jido_messaging__(:agent_supervisor))
    true = Process.unregister(Instance.__jido_messaging__(:agent_supervisor))

    try do
      assert {:error, {:stop_agent_failed, {:supervisor_unavailable, _}}} =
               Instance.unassign_thread(room.id, thread.id)

      assert {:ok, ^assigned} = Instance.get_thread(thread.id)
      assert RoomServer.thread_assignment(server, thread.id) == "alpha"
      assert AgentRunner.whereis(Instance, room.id, thread.id, "alpha") == runner
      assert Process.alive?(supervisor)
    after
      true = Process.register(agent_supervisor, Instance.__jido_messaging__(:agent_supervisor))
    end

    assert {:ok, cleared} = Instance.unassign_thread(room.id, thread.id)
    assert cleared.assigned_agent_id == nil
    assert RoomServer.thread_assignment(server, thread.id) == nil
    assert AgentRunner.whereis(Instance, room.id, thread.id, "alpha") == nil
    assert_authority_empty()
  end

  for child <- [:runtime, :room_supervisor] do
    test "restoration safely rejects a stopped #{child}" do
      supervisor = Instance.__jido_messaging__(:supervisor)

      name =
        if unquote(child) == :runtime,
          do: Instance.__jido_messaging__(:runtime),
          else: Module.concat(Instance, :RoomSupervisor)

      pid = Process.whereis(name)

      {id, ^pid, _, _} =
        Enum.find(Supervisor.which_children(supervisor), fn {_, child_pid, _, _} -> child_pid == pid end)

      assert :ok = Supervisor.terminate_child(supervisor, id)
      assert {:error, :runtime_unavailable} = Jido.Messaging.restore_agent_runners(Instance)
    end
  end

  defp room(id) do
    {:ok, room} = Instance.create_room(%{id: id, type: :group})
    {:ok, _} = RoomSupervisor.get_or_start_room(Instance, room)
    room
  end

  defp register(room_id, agent_id) do
    assert {:ok, _} = Instance.register_agent(room_id, %{agent_id: agent_id, handler: fn _, _ -> :noreply end})
  end

  defp assert_authority_empty do
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    assert :ets.info(state.memberships, :size) == 0
    assert :ets.info(state.principal_grants, :size) == 0
    assert :ets.info(state.messages, :size) == 0
  end
end
