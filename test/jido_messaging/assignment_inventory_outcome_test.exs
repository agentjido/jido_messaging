defmodule Jido.Messaging.AssignmentInventoryOutcomeTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{AgentRunner, AgentSupervisor, Persistence.ETS, RoomServer, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name not in [:list_threads, :save_thread] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_thread(state, thread) do
      Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes + 1})
      ETS.save_thread(state, thread)
    end

    def list_threads(state, room, opts \\ []) do
      case Agent.get(__MODULE__.Control, & &1.mode) do
        :pass -> ETS.list_threads(state, room, opts)
        :error -> {:error, :assignment_inventory_unavailable}
        :raise -> raise "private assignment inventory"
        :throw -> throw(:private_assignment_inventory)
        :exit -> exit(:private_assignment_inventory)
        :invalid -> :invalid
        {:result, value} -> {:ok, value}
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{mode: :pass, writes: 0} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "inventory-owned", type: :group})
    {:ok, foreign_room} = Instance.create_room(%{id: "inventory-foreign", type: :group})

    for selected <- [room, foreign_room] do
      {:ok, _} = Instance.register_agent(selected.id, spec("alpha"))
    end

    {:ok, thread} = Instance.save_thread(%{id: "owned-thread", room_id: room.id})
    {:ok, assigned} = Instance.assign_thread(room.id, thread.id, "alpha")
    {:ok, foreign} = Instance.save_thread(%{id: "foreign-thread", room_id: foreign_room.id})
    {:ok, foreign} = Instance.assign_thread(foreign_room.id, foreign.id, "alpha")
    Agent.update(Store.Control, &%{&1 | writes: 0})

    {:ok,
     room: room,
     foreign_room: foreign_room,
     assigned: assigned,
     foreign: foreign,
     server: RoomServer.whereis(Instance, room.id),
     runner: AgentRunner.whereis(Instance, room.id, assigned.id, "alpha"),
     foreign_runner: AgentRunner.whereis(Instance, foreign_room.id, foreign.id, "alpha")}
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "unregister #{failure} inventory keeps registration and both assigned runners", context do
      set_mode(unquote(failure))
      expected = expected(unquote(failure))
      assert {:error, ^expected} = Instance.unregister_agent(context.room.id, "alpha")
      assert_preserved(context)
      set_mode(:pass)
      assert :ok = Instance.unregister_agent(context.room.id, "alpha")
      assert {:ok, cleared} = Instance.get_thread(context.assigned.id)
      assert cleared.assigned_agent_id == nil
      assert AgentRunner.whereis(Instance, context.room.id, cleared.id, "alpha") == nil
      assert Process.alive?(context.foreign_runner)
      assert Agent.get(Store.Control, & &1.writes) == 1
    end

    test "register #{failure} inventory returns error before adding a new agent", context do
      set_mode(unquote(failure))
      expected = expected(unquote(failure))
      assert {:error, ^expected} = Instance.register_agent(context.room.id, spec("beta"))
      assert {:ok, agents} = Instance.list_agents(context.room.id)
      assert Enum.map(agents, & &1.agent_id) == ["alpha"]
      assert_preserved(context)
    end

    test "explicit restore #{failure} inventory reports failure without changing owned runners", context do
      set_mode(unquote(failure))
      expected = expected(unquote(failure))
      assert {:error, ^expected} = Jido.Messaging.restore_agent_runners(Instance)
      assert_preserved(context)
    end
  end

  test "whole malformed or foreign assignment lists cannot cause partial unregister", context do
    for bad <- [
          nil,
          %{},
          %{context.assigned | id: nil},
          %{context.assigned | room_id: context.foreign_room.id},
          %{context.assigned | assigned_agent_id: self()},
          context.foreign
        ] do
      set_mode({:result, [context.assigned, bad]})
      assert {:error, :persistence_failed} = Instance.unregister_agent(context.room.id, "alpha")
      assert_preserved(context)
    end
  end

  test "duplicate thread identities cannot run cleanup twice", context do
    set_mode({:result, [context.assigned, context.assigned]})
    assert {:error, :persistence_failed} = Instance.unregister_agent(context.room.id, "alpha")
    assert_preserved(context)
  end

  test "runner restoration failure returns error and retains registration and assigned record", context do
    assert :ok = AgentSupervisor.stop_agent(Instance, context.room.id, context.assigned.id, "alpha")
    name = Instance.__jido_messaging__(:agent_supervisor)
    supervisor = Process.whereis(name)
    true = Process.unregister(name)

    try do
      assert {:error, {:start_agent_failed, {:supervisor_unavailable, _}}} =
               Instance.register_agent(context.room.id, spec("alpha"))

      assert {:ok, stored} = Instance.get_thread(context.assigned.id)
      assert stored == context.assigned
      assert RoomServer.thread_assignment(context.server, stored.id) == "alpha"
      assert {:ok, agents} = Instance.list_agents(context.room.id)
      assert Enum.any?(agents, &(&1.agent_id == "alpha"))
      assert Process.alive?(context.foreign_runner)
    after
      true = Process.register(supervisor, name)
    end

    assert :ok = Jido.Messaging.restore_agent_runners(Instance)
    assert AgentSupervisor.count_agents(Instance) == 2
    assert Agent.get(Store.Control, & &1.writes) == 0
  end

  defp spec(id), do: %{agent_id: id, handler: fn _, _ -> :noreply end, name: "Complete " <> id}
  defp set_mode(mode), do: Agent.update(Store.Control, &%{&1 | mode: mode})
  defp expected(:error), do: :assignment_inventory_unavailable
  defp expected(_), do: :persistence_failed

  defp assert_preserved(context) do
    assert {:ok, stored} = Instance.get_thread(context.assigned.id)
    assert stored == context.assigned
    assert {:ok, foreign} = Instance.get_thread(context.foreign.id)
    assert foreign == context.foreign
    assert RoomServer.thread_assignment(context.server, stored.id) == "alpha"
    assert AgentRunner.whereis(Instance, context.room.id, stored.id, "alpha") == context.runner
    assert Process.alive?(context.runner)
    assert Process.alive?(context.foreign_runner)
    assert AgentSupervisor.count_agents(Instance) == 2
    assert Agent.get(Store.Control, & &1.writes) == 0
    assert {:ok, agents} = Instance.list_agents(context.room.id)
    assert Enum.any?(agents, &(&1.agent_id == "alpha"))
    {_store, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    assert :ets.info(state.principal_grants, :size) == 0
    assert :ets.info(state.messages, :size) == 0
    assert Jido.Messaging.TestHelpers.runtime_entry_count(Instance.__jido_messaging__(:runtime)) == 0
  end
end
