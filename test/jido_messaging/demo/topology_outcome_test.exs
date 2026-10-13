defmodule Jido.Messaging.Demo.TopologyOutcomeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.AdapterTestKit.MockAdapter
  alias Jido.Messaging.Demo.Topology

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    :ok
  end

  for {entry, reason} <- [
        {%{"bridge_configs" => [%{"adapter_module" => nil}]}, :invalid_bridge_config},
        {%{"bridge_rooms" => [%{"bridge_configs" => [%{"adapter_module" => nil}]}]}, :invalid_bridge_room},
        {%{"rooms" => [%{"id" => ""}]}, :invalid_room},
        {%{"routing_policies" => [%{}]}, :invalid_routing_policy},
        {%{"room_bindings" => [%{"room_id" => "room", "bridge_id" => "bridge", "channel" => "telegram"}]},
         :invalid_room_binding}
      ] do
    test "invalid #{reason} retains no canonical room or bridge config" do
      assert {:error, error} = Topology.apply(Instance, unquote(Macro.escape(entry)))
      assert elem(error, 0) == unquote(reason)
      assert {:ok, []} = Instance.list_rooms()
      assert [] = Instance.list_bridge_configs()
    end
  end

  test "raw bridge credentials reject before following room sections" do
    topology = %{
      "bridge_configs" => [
        %{"id" => "unsafe", "adapter_module" => MockAdapter, "credentials" => %{"token" => "fixture"}}
      ],
      "rooms" => [%{"id" => "not-created"}]
    }

    assert {:error, {:bridge_config_failed, :raw_bridge_credentials_not_allowed, _}} =
             Topology.apply(Instance, topology)

    assert {:error, :not_found} = Instance.get_bridge_config("unsafe")
    assert {:ok, []} = Instance.list_rooms()
  end

  for missing <- ~w(room_id bridge_id external_room_id channel) do
    test "missing #{missing} cannot create a binding under a nil-derived identity" do
      entry = %{"room_id" => "room", "bridge_id" => "bridge", "external_room_id" => "peer", "channel" => "telegram"}
      incomplete = Map.delete(entry, unquote(missing))

      assert {:error, {:invalid_room_binding, ^incomplete}} =
               Topology.apply(Instance, %{"room_bindings" => [incomplete]})

      assert {:ok, []} = Instance.list_room_bindings("room")
      assert {:ok, []} = Instance.list_room_bindings("nil")
      assert {:ok, []} = Instance.list_rooms()
    end
  end

  for missing <- [:external_room_id, :channel] do
    test "bridge-room creation rejects missing #{missing} before a provider binding is stored" do
      binding = %{channel: :telegram, bridge_id: "bridge", external_room_id: "peer"}
      incomplete = Map.delete(binding, unquote(missing))

      assert {:error, {:invalid_binding, ^incomplete}} =
               Instance.create_bridge_room(%{
                 room_id: "declared-room",
                 bridge_configs: [%{id: "bridge", adapter_module: MockAdapter}],
                 bindings: [incomplete]
               })

      assert {:ok, []} = Instance.list_room_bindings("declared-room")
    end
  end

  test "later invalid room retains earlier applied bridge config and valid room in declared order" do
    topology = %{
      "bridge_configs" => [%{"id" => "kept", "adapter_module" => MockAdapter, "enabled" => false}],
      "rooms" => [%{"id" => "kept-room", "type" => "thread"}, %{"id" => ""}],
      "routing_policies" => [%{"room_id" => "kept-room", "delivery_mode" => "broadcast"}]
    }

    assert {:error, {:invalid_room, _}} = Topology.apply(Instance, topology)
    assert {:ok, bridge} = Instance.get_bridge_config("kept")
    assert bridge.enabled == false
    assert {:ok, [room]} = Instance.list_rooms()
    assert room.id == "kept-room"
    assert room.type == :thread
    assert {:error, :not_found} = Instance.get_routing_policy(room.id)
  end

  test "unknown topology keys remain strings and existing room values are not replaced" do
    unknown = "topology_key_#{System.unique_integer([:positive])}"
    assert {:ok, original} = Instance.create_room(%{id: "existing", type: :direct, name: "Original"})

    assert {:ok, %{rooms: 1}} =
             Topology.apply(Instance, %{
               "rooms" => [%{"id" => original.id, "type" => "channel", "name" => "Changed", unknown => "ignored"}]
             })

    assert {:ok, ^original} = Instance.get_room(original.id)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end
end
