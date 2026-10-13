defmodule Jido.Messaging.Demo.CheckpointTopologyContractTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.Demo.Topology

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    :ok
  end

  test "all declared mode forms resolve and an unknown mode has no implicit default" do
    for mode <- [:echo, :bridge, :agent] do
      assert Topology.mode(%{mode: mode}) == mode
      assert Topology.mode(%{"mode" => Atom.to_string(mode)}) == mode
    end

    assert Topology.mode(%{mode: :unknown}) == nil
    assert Topology.adapter_module(%{bridge: %{adapter: 12}}, "adapter") == nil
    path = Path.join(System.tmp_dir!(), "absent-topology-#{System.unique_integer([:positive])}.yaml")
    assert {:error, {:not_found, ^path}} = Topology.load(path)
  end

  test "binding input conversion preserves declared direction and enabled states" do
    for {direction, expected_direction} <- [
          {:both, :both},
          {:inbound, :inbound},
          {:outbound, :outbound},
          {"outbound", :outbound},
          {:unknown, :both}
        ],
        {enabled, expected_enabled} <- [
          {false, false},
          {"true", true},
          {"1", true},
          {"0", false},
          {1, true},
          {0, false}
        ] do
      id = "room-#{System.unique_integer([:positive])}"

      topology = %{
        rooms: [%{id: id, type: :channel}],
        room_bindings: [
          %{
            room_id: id,
            channel: :discord,
            bridge_id: :bridge,
            external_room_id: id,
            direction: direction,
            enabled: enabled
          }
        ]
      }

      assert {:ok, %{rooms: 1, room_bindings: 1}} = Topology.apply(Instance, topology)
      assert {:ok, [binding]} = Instance.list_room_bindings(id)
      assert binding.direction == expected_direction
      assert binding.enabled == expected_enabled
      assert binding.bridge_id == "bridge"
      assert {:ok, room} = Instance.get_room(id)
      assert room.type == :channel
    end
  end

  test "invalid provider identity cannot create a binding or change another room" do
    {:ok, foreign} = Instance.create_room(%{id: "foreign", type: :group, metadata: %{complete: true}})

    for channel <- [:unknown, "unknown"], room_id <- [nil, []] do
      input = %{room_bindings: [%{room_id: room_id, channel: channel, bridge_id: "bridge", external_room_id: "peer"}]}
      assert {:error, {:invalid_room_binding, _}} = Topology.apply(Instance, input)
      assert {:ok, ^foreign} = Instance.get_room(foreign.id)
      assert {:ok, []} = Instance.list_room_bindings(foreign.id)
    end

    assert {:error, {:invalid_routing_policy, _}} = Topology.apply(Instance, %{routing_policies: [%{}]})

    assert {:error, {:invalid_bridge_room, :invalid_adapter_module, _}} =
             Topology.apply(Instance, %{
               bridge_rooms: [%{room_id: "not-created", bridge_configs: [%{adapter_module: 12}]}]
             })

    assert {:error, :not_found} = Instance.get_room("not-created")
  end

  test "a composite room without provider bindings retains complete room metadata" do
    input = %{bridge_rooms: [%{room_id: "composite", room_type: "channel", room_metadata: %{complete: ["one", "two"]}}]}
    assert {:ok, %{bridge_rooms: 1}} = Topology.apply(Instance, input)
    assert {:ok, room} = Instance.get_room("composite")
    assert room.type == :channel
    assert room.metadata == %{complete: ["one", "two"]}

    assert {:ok, %{rooms: 1}} =
             Topology.apply(Instance, %{rooms: [%{id: "thread-room", type: :thread, external_bindings: %{}}]})

    assert {:ok, %{rooms: 1}} = Topology.apply(Instance, %{rooms: [%{id: "default-room", type: :unknown}]})
    assert {:ok, %{type: :group}} = Instance.get_room("default-room")
  end

  test "malformed nested bridge configuration fails before composite room creation" do
    input = %{bridge_rooms: [%{room_id: "must-not-exist", bridge_configs: :invalid}]}
    assert {:error, {:invalid_bridge_room, :invalid_bridge_configs, _}} = Topology.apply(Instance, input)
    assert {:error, :not_found} = Instance.get_room("must-not-exist")
    assert [] = Instance.list_bridge_configs()
  end
end
