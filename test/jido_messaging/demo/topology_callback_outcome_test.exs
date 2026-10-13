defmodule Jido.Messaging.Demo.TopologyCallbackOutcomeTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Room
  alias Jido.Messaging.{Demo.Topology, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    @controlled [:get_room, :save_room, :get_room_by_external_binding, :create_room_binding]
    for {name, arity} <- ETS.__info__(:functions), name not in @controlled do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def get_room(state, id), do: call(:room_read, fn -> ETS.get_room(state, id) end)
    def save_room(state, room), do: call(:room_write, fn -> ETS.save_room(state, room) end)

    def get_room_by_external_binding(state, channel, bridge, external),
      do: call(:binding_read, fn -> ETS.get_room_by_external_binding(state, channel, bridge, external) end)

    def create_room_binding(state, room, channel, bridge, external, attrs),
      do: call(:binding_write, fn -> ETS.create_room_binding(state, room, channel, bridge, external, attrs) end)

    defp call(operation, fun) do
      mode =
        Agent.get_and_update(__MODULE__.Control, fn data ->
          {Map.get(data.modes, operation, :pass), %{data | calls: data.calls ++ [operation]}}
        end)

      case mode do
        :pass ->
          fun.()

        {:after_write, failure} ->
          result = fun.()
          Agent.update(__MODULE__.Control, &%{&1 | writes: &1.writes ++ [result]})
          fail(failure)

        {:result, value} ->
          value

        failure ->
          fail(failure)
      end
    end

    defp fail(:error), do: {:error, :topology_store_unavailable}
    defp fail(:raise), do: raise("private topology store")
    defp fail(:throw), do: throw(:private_topology_store)
    defp fail(:exit), do: exit(:private_topology_store)
    defp fail(:invalid), do: {:ok, :private_topology_store}
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{
      id: Store.Control,
      start: {Agent, :start_link, [fn -> %{modes: %{}, calls: [], writes: []} end, [name: Store.Control]]}
    })

    start_supervised!(Instance)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)
    room = Room.new(%{id: "owned-room", type: :group, name: "Complete owned room", metadata: %{retained: "owned"}})

    foreign =
      Room.new(%{id: "foreign-room", type: :direct, name: "Complete foreign room", metadata: %{retained: "foreign"}})

    assert {:ok, ^room} = ETS.save_room(state, room)
    assert {:ok, ^foreign} = ETS.save_room(state, foreign)
    {:ok, runtime: runtime, state: state, room: room, foreign: foreign}
  end

  for operation <- [:room_read, :room_write, :binding_read, :binding_write],
      failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{operation} #{failure} stops setup before later effects", context do
      mode(unquote(operation), unquote(failure))
      topology = topology(unquote(operation))
      assert {:error, {reason, _failure, _entry}} = Topology.apply(Instance, topology)
      assert reason == reason(unquote(operation))
      data = Agent.get(Store.Control, & &1)
      assert data.calls == calls(unquote(operation))
      assert data.writes == []
      assert {:error, :not_found} = ETS.get_room(context.state, "new-room")
      assert {:ok, []} = ETS.list_room_bindings(context.state, context.room.id)
      assert {:ok, owned} = ETS.get_room(context.state, context.room.id)
      assert owned == context.room
      assert_foreign_and_authority(context)
    end
  end

  for operation <- [:room_write, :binding_write], failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{operation} #{failure} after write retains one complete effect and safe retry", context do
      mode(unquote(operation), {:after_write, unquote(failure)})
      topology = topology(unquote(operation))
      assert {:error, {reason, _, _}} = Topology.apply(Instance, topology)
      assert reason == reason(unquote(operation))
      assert [written] = Agent.get(Store.Control, & &1.writes)
      assert {:ok, record} = written

      if unquote(operation) == :room_write do
        assert {:ok, ^record} = ETS.get_room(context.state, "new-room")
        assert record.name == "New complete room"
        assert record.metadata == %{"retained" => "new"}
      else
        assert {:ok, [^record]} = ETS.list_room_bindings(context.state, context.room.id)
        assert record.external_room_id == "provider-room"
        assert record.bridge_id == "bridge"
      end

      assert_foreign_and_authority(context)
      mode(unquote(operation), :pass)
      assert {:ok, _summary} = Topology.apply(Instance, topology)
      assert Agent.get(Store.Control, & &1.writes) == [written]

      if unquote(operation) == :room_write do
        assert {:ok, ^record} = ETS.get_room(context.state, "new-room")
      else
        assert {:ok, [^record]} = ETS.list_room_bindings(context.state, context.room.id)
      end

      assert {:ok, policy} = Instance.get_routing_policy(context.room.id)
      assert policy.delivery_mode == :broadcast
      assert {:ok, foreign} = ETS.get_room(context.state, context.foreign.id)
      assert foreign == context.foreign
    end
  end

  test "foreign room lookup cannot claim the requested room exists", context do
    mode(:room_read, {:result, {:ok, context.foreign}})

    assert {:error, {:room_lookup_failed, :invalid_topology_result, _}} =
             Topology.apply(Instance, topology(:room_read))

    assert_foreign_and_authority(context)
    assert Agent.get(Store.Control, & &1.calls) == [:room_read]
  end

  test "foreign binding result cannot permit the routing policy", context do
    foreign =
      Jido.Messaging.RoomBinding.new(%{
        room_id: context.foreign.id,
        channel: :telegram,
        bridge_id: "bridge",
        external_room_id: "provider-room"
      })

    mode(:binding_write, {:result, {:ok, foreign}})

    assert {:error, {:room_binding_failed, :invalid_topology_result, _}} =
             Topology.apply(Instance, topology(:binding_write))

    assert_foreign_and_authority(context)
    assert {:ok, []} = ETS.list_room_bindings(context.state, context.room.id)
  end

  defp mode(operation, value), do: Agent.update(Store.Control, &%{&1 | modes: Map.put(&1.modes, operation, value)})
  defp reason(:room_read), do: :room_lookup_failed
  defp reason(:room_write), do: :room_create_failed
  defp reason(:binding_read), do: :room_binding_lookup_failed
  defp reason(:binding_write), do: :room_binding_failed
  defp calls(:room_read), do: [:room_read]
  defp calls(:room_write), do: [:room_read, :room_write]
  defp calls(:binding_read), do: [:binding_read]
  defp calls(:binding_write), do: [:binding_read, :binding_write]

  defp topology(operation) do
    section =
      if operation in [:room_read, :room_write] do
        %{"rooms" => [%{"id" => "new-room", "name" => "New complete room", "metadata" => %{"retained" => "new"}}]}
      else
        %{
          "room_bindings" => [
            %{
              "room_id" => "owned-room",
              "channel" => "telegram",
              "bridge_id" => "bridge",
              "external_room_id" => "provider-room"
            }
          ]
        }
      end

    Map.put(section, "routing_policies", [%{"room_id" => "owned-room", "delivery_mode" => "broadcast"}])
  end

  defp assert_foreign_and_authority(context) do
    assert {:ok, foreign} = ETS.get_room(context.state, context.foreign.id)
    assert foreign == context.foreign
    assert {:ok, []} = ETS.list_room_bindings(context.state, context.foreign.id)
    assert {:error, :not_found} = Instance.get_routing_policy(context.room.id)
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert Instance.count_agents() == 0
  end
end
