defmodule Jido.Messaging.RoomTypingTimeoutTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.{Events, RoomServer, RoomSupervisor}
  alias Jido.Messaging.Signal.Identity

  defmodule Runtime do
    use Jido.Messaging
  end

  setup do
    start_supervised!(Runtime)
    {:ok, room} = Runtime.create_room(%{type: :group})
    {:ok, server} = RoomSupervisor.get_or_start_room(Runtime, room)

    {:ok, _} =
      Jido.Signal.Bus.subscribe(Module.concat(Runtime, SignalBus), "jido.messaging.participant.typing",
        selector: [source: Events.source(Runtime), subject: Identity.room_subject(room.id)]
      )

    {:ok, room: room, server: server}
  end

  test "expired typing emits false while stale and unknown timers have no fact", %{server: server, room: room} do
    assert :ok = RoomServer.set_typing(server, "owned-participant", true, thread_id: "owned-thread")
    assert_receive {:signal, started}
    assert started.data["typing"] == true
    assert started.data["thread_id"] == "owned-thread"

    send(server, {:typing_timeout, "owned-participant", "owned-thread"})
    assert [%{participant_id: "owned-participant", thread_id: "owned-thread"}] = RoomServer.get_typing(server)
    refute_receive {:signal, _}, 0
    send(server, {:typing_timeout, "unknown-participant", "owned-thread"})
    RoomServer.get_state(server)
    refute_receive {:signal, _}, 0

    :sys.replace_state(server, fn state ->
      %{
        state
        | typing:
            Map.put(state.typing, {"owned-participant", "owned-thread"}, DateTime.add(DateTime.utc_now(), -1, :second))
      }
    end)

    send(server, {:typing_timeout, "owned-participant", "owned-thread"})
    assert [] = RoomServer.get_typing(server)
    assert_receive {:signal, stopped}
    assert stopped.data["typing"] == false
    assert stopped.data["participant_id"] == "owned-participant"
    assert stopped.data["room_id"] == room.id
    assert stopped.data["thread_id"] == "owned-thread"
    assert stopped.source == Events.source(Runtime)
    assert stopped.subject == Identity.room_subject(room.id)
    assert {:ok, ^stopped} = stopped |> Jido.Signal.to_map() |> Jido.Signal.from_map()

    send(server, {:typing_timeout, "owned-participant", "owned-thread"})
    RoomServer.get_state(server)
    refute_receive {:signal, _}, 0
  end
end
