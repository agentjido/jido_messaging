defmodule Jido.Messaging.Demo.BridgeSetupOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Demo.Bridge

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule ControlledInstance do
    defdelegate get_room(id), to: Instance
    defdelegate save_room(room), to: Instance

    def get_room_by_external_binding(channel, bridge, external) do
      case Process.get(:lookup_failure) do
        :error -> {:error, :lookup_unavailable}
        :raise -> raise "private lookup failure"
        :throw -> throw(:private_lookup_failure)
        :exit -> exit(:private_lookup_failure)
        :invalid -> :invalid
        _ -> Instance.get_room_by_external_binding(channel, bridge, external)
      end
    end

    def create_room_binding(room, channel, bridge, external, attrs) do
      send(self(), {:binding_attempt, channel, bridge, external})

      case Process.get(:setup_failure) do
        ^channel -> {:error, :binding_unavailable}
        :raise -> raise "private binding failure"
        :throw -> throw(:private_binding_failure)
        :exit -> exit(:private_binding_failure)
        :invalid -> :invalid
        _ -> Instance.create_room_binding(room, channel, bridge, external, attrs)
      end
    end
  end

  for failure <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{failure} preflight lookup fails before writes or subscription", %{state: state, room: room} do
      Process.put(:lookup_failure, unquote(failure))
      assert {:noreply, ^state} = Bridge.handle_info(:setup_shared_room, state)
      refute_receive :subscribe, 0
      refute_receive {:binding_attempt, _, _, _}, 0
      assert {:ok, []} = Instance.list_room_bindings(room.id)
    end
  end

  for failure <- [:raise, :throw, :exit, :invalid] do
    test "#{failure} binding callback prevents subscription and preserves retry", %{state: state, room: room} do
      Process.put(:setup_failure, unquote(failure))
      assert {:noreply, ^state} = Bridge.handle_info(:setup_shared_room, state)
      assert_receive {:binding_attempt, :telegram, "tg", "tg-room"}
      refute_receive :subscribe, 0
      assert {:ok, []} = Instance.list_room_bindings(room.id)
      Process.delete(:setup_failure)
      assert {:noreply, ^state} = Bridge.handle_info(:setup_shared_room, state)
      assert_receive :subscribe
      assert {:ok, routes} = Instance.list_room_bindings(room.id)
      assert length(routes) == 2
    end
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "demo:lobby", type: :group})

    state = %Bridge{
      instance_module: ControlledInstance,
      room_id: room.id,
      bindings: [{:telegram, __MODULE__, "tg", "tg-room"}, {:discord, __MODULE__, "dc", "dc-room"}]
    }

    {:ok, room: room, state: state}
  end

  test "failed second write does not subscribe and retry keeps the first binding", %{room: room, state: state} do
    Process.put(:setup_failure, :discord)
    assert {:noreply, ^state} = Bridge.handle_info(:setup_shared_room, state)
    assert_receive {:binding_attempt, :telegram, "tg", "tg-room"}
    assert_receive {:binding_attempt, :discord, "dc", "dc-room"}
    refute_receive :subscribe, 0
    assert {:ok, [first]} = Instance.list_room_bindings(room.id)

    Process.delete(:setup_failure)
    assert {:noreply, ^state} = Bridge.handle_info(:setup_shared_room, state)
    assert_receive {:binding_attempt, :discord, "dc", "dc-room"}
    refute_receive {:binding_attempt, :telegram, _, _}, 0
    assert_receive :subscribe
    assert {:ok, routes} = Instance.list_room_bindings(room.id)
    assert length(routes) == 2
    assert first in routes
  end

  test "foreign room route rejects complete setup before other writes", %{state: state, room: room} do
    {:ok, foreign} = Instance.create_room(%{id: "foreign-room", type: :group})
    {:ok, owned_foreign} = Instance.create_room_binding(foreign.id, :discord, "dc", "dc-room")
    assert {:noreply, ^state} = Bridge.handle_info(:setup_shared_room, state)
    refute_receive :subscribe, 0
    refute_receive {:binding_attempt, _, _, _}, 0
    assert {:ok, []} = Instance.list_room_bindings(room.id)
    assert {:ok, [^owned_foreign]} = Instance.list_room_bindings(foreign.id)
    assert {:ok, ^foreign} = Instance.get_room_by_external_binding(:discord, "dc", "dc-room")
  end
end
