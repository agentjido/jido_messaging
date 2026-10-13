defmodule Jido.Messaging.AgentAssignmentStoreFailureTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{AgentRunner, AgentSupervisor, RoomServer, Runtime}
  alias Jido.Messaging.Persistence.ETS

  defmodule Store do
    @behaviour Jido.Messaging.Persistence

    for {name, arity} <- ETS.__info__(:functions), name != :save_thread do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_thread(state, thread) do
      Process.put({__MODULE__, :attempts}, Process.get({__MODULE__, :attempts}, 0) + 1)

      case Process.get({__MODULE__, :responses}, []) do
        [] ->
          ETS.save_thread(state, thread)

        [:pass | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          ETS.save_thread(state, thread)

        [{:after_write, failure} | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          {:ok, _} = ETS.save_thread(state, thread)
          fail(failure)

        [:foreign_record | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          {:ok, %{thread | room_id: "foreign-room"}}

        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          fail(response)
      end
    end

    defp fail(:error), do: {:error, :save_unavailable}
    defp fail(:raise), do: raise("private thread save error")
    defp fail(:throw), do: throw(:private_thread_save_error)
    defp fail(:exit), do: exit(:private_thread_save_error)
    defp fail(:invalid), do: :invalid
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "assignment-store-room", type: :group})

    for agent <- ["alpha", "beta"] do
      assert {:ok, _} = Instance.register_agent(room.id, %{agent_id: agent, handler: fn _, _ -> :noreply end})
    end

    assert {:ok, thread} = Instance.save_thread(%{id: "thread", room_id: room.id})
    assert {:ok, assigned} = Instance.assign_thread(room.id, thread.id, "alpha")
    %{room: room, assigned: assigned, server: RoomServer.whereis(Instance, room.id)}
  end

  test "reassignment save error restores the old assignment and exactly one runner", context do
    fail_next([:error, :pass])
    assert {:error, :save_unavailable} = Instance.assign_thread(context.room.id, context.assigned.id, "beta")
    assert_old_assignment(context)
    assert Process.get({Store, :attempts}) == 2
    assert {:ok, changed} = Instance.assign_thread(context.room.id, context.assigned.id, "beta")
    assert changed.assigned_agent_id == "beta"
    assert AgentRunner.whereis(Instance, context.room.id, context.assigned.id, "alpha") == nil
    assert is_pid(AgentRunner.whereis(Instance, context.room.id, context.assigned.id, "beta"))
    assert AgentSupervisor.count_agents(Instance) == 1
  end

  test "unassignment save error restores the old assignment and permits one later cleanup", context do
    fail_next([:error, :pass])
    assert {:error, :save_unavailable} = Instance.unassign_thread(context.room.id, context.assigned.id)
    assert_old_assignment(context)
    assert Process.get({Store, :attempts}) == 2
    assert {:ok, cleared} = Instance.unassign_thread(context.room.id, context.assigned.id)
    assert cleared.assigned_agent_id == nil
    assert RoomServer.thread_assignment(context.server, context.assigned.id) == nil
    assert AgentSupervisor.count_agents(Instance) == 0
  end

  for operation <- [:assign, :unassign], failure <- [:raise, :throw, :exit, :invalid, :foreign_record] do
    test "#{operation} #{failure} save failure returns safely and restores owned state", context do
      fail_next([unquote(failure), :pass])

      result =
        if unquote(operation) == :assign,
          do: Instance.assign_thread(context.room.id, context.assigned.id, "beta"),
          else: Instance.unassign_thread(context.room.id, context.assigned.id)

      assert {:error, _} = result
      assert_old_assignment(context)
      assert Process.get({Store, :attempts}) == 2
    end
  end

  for operation <- [:assign, :unassign], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{operation} after-write #{failure} restores the original stored and runtime assignment", context do
      fail_next([{:after_write, unquote(failure)}, :pass])
      result = assignment_operation(unquote(operation), context)
      assert {:error, _} = result
      assert_old_assignment(context)
      assert Process.get({Store, :attempts}) == 2
    end
  end

  for operation <- [:assign, :unassign] do
    test "#{operation} reports both save and rollback failure without claiming restoration", context do
      fail_next([:error, :error])
      result = assignment_operation(unquote(operation), context)
      wrapper = if unquote(operation) == :assign, do: :assignment_failed, else: :unassignment_failed
      assert {:error, {^wrapper, :save_unavailable, :save_unavailable}} = result
      assert {:ok, stored} = Instance.get_thread(context.assigned.id)
      assert stored.assigned_agent_id == "alpha"
      assert RoomServer.thread_assignment(context.server, stored.id) == "alpha"
      assert AgentSupervisor.count_agents(Instance) == 0
      assert Process.get({Store, :attempts}) == 2
      assert :ok = Jido.Messaging.restore_agent_runners(Instance)
      assert_old_assignment(context)
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid, :foreign_record] do
    test "unregister #{failure} save failure retains registration and restores the old assignment", context do
      fail_next([unquote(failure), :pass])
      assert {:error, _} = Instance.unregister_agent(context.room.id, "alpha")
      assert_old_assignment(context)
      assert {:ok, agents} = Instance.list_agents(context.room.id)
      assert Enum.any?(agents, &(&1.agent_id == "alpha"))
      assert Process.get({Store, :attempts}) == 2
      assert :ok = Instance.unregister_agent(context.room.id, "alpha")
      assert {:ok, cleared} = Instance.get_thread(context.assigned.id)
      assert cleared.assigned_agent_id == nil
      assert AgentSupervisor.count_agents(Instance) == 0
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "unregister after-write #{failure} cannot remove the agent after a failed cleanup", context do
      fail_next([{:after_write, unquote(failure)}, :pass])
      assert {:error, _} = Instance.unregister_agent(context.room.id, "alpha")
      assert_old_assignment(context)
      assert Process.get({Store, :attempts}) == 2
      assert {:ok, agents} = Instance.list_agents(context.room.id)
      assert Enum.any?(agents, &(&1.agent_id == "alpha"))
    end
  end

  test "unregister reports cleanup and rollback failure while retaining registration", context do
    fail_next([:error, :error])

    assert {:error, {:unassignment_failed, :save_unavailable, :save_unavailable}} =
             Instance.unregister_agent(context.room.id, "alpha")

    assert {:ok, agents} = Instance.list_agents(context.room.id)
    assert Enum.any?(agents, &(&1.agent_id == "alpha"))
    assert {:ok, stored} = Instance.get_thread(context.assigned.id)
    assert stored == context.assigned
    assert AgentSupervisor.count_agents(Instance) == 0
    assert :ok = Jido.Messaging.restore_agent_runners(Instance)
    assert_old_assignment(context)
  end

  test "unregister clears an absent thread runtime assignment without a store write", context do
    {_store, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    :ets.delete(state.threads, context.assigned.id)
    fail_next([])
    assert :ok = Instance.unregister_agent(context.room.id, "alpha")
    assert AgentSupervisor.count_agents(Instance) == 0
    assert RoomServer.thread_assignment(context.server, context.assigned.id) == nil
    assert Process.get({Store, :attempts}) == 0
    assert {:ok, agents} = Instance.list_agents(context.room.id)
    refute Enum.any?(agents, &(&1.agent_id == "alpha"))
  end

  defp assignment_operation(:assign, context),
    do: Instance.assign_thread(context.room.id, context.assigned.id, "beta")

  defp assignment_operation(:unassign, context), do: Instance.unassign_thread(context.room.id, context.assigned.id)

  defp fail_next(responses) do
    Process.put({Store, :attempts}, 0)
    Process.put({Store, :responses}, responses)
  end

  defp assert_old_assignment(context) do
    assert {:ok, stored} = Instance.get_thread(context.assigned.id)
    assert stored == context.assigned
    assert RoomServer.thread_assignment(context.server, stored.id) == "alpha"
    assert is_pid(AgentRunner.whereis(Instance, context.room.id, stored.id, "alpha"))
    assert AgentRunner.whereis(Instance, context.room.id, stored.id, "beta") == nil
    assert AgentSupervisor.count_agents(Instance) == 1
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    assert :ets.info(state.principal_grants, :size) == 0
    assert :ets.info(state.messages, :size) == 0
  end
end
