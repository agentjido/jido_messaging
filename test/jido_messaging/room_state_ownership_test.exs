defmodule Jido.Messaging.RoomStateOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{Message, RoomServer}

  defmodule Runtime do
    use Jido.Messaging
  end

  setup do
    start_supervised!(Runtime)
    room = Room.new(%{type: :group})
    {:ok, server} = RoomServer.start_link(room: room, instance_module: Runtime, message_limit: 2)
    {:ok, room: room, server: server}
  end

  test "all recipients determine receipt state and duplicate receipts keep timestamps", %{room: room, server: server} do
    sender = participant("sender")
    alice = participant("alice")
    bob = participant("bob")
    for person <- [sender, alice, bob], do: assert(:ok == RoomServer.add_participant(server, person))
    message = message(room, "root")
    assert :ok = RoomServer.add_message(server, message)
    assert {:ok, first} = RoomServer.mark_delivered(server, message.id, alice.id)
    assert first.status == :sent
    assert {:ok, :already_delivered} = RoomServer.mark_delivered(server, message.id, alice.id)
    assert {:ok, delivered} = RoomServer.mark_delivered(server, message.id, bob.id)
    assert delivered.status == :delivered
    assert delivered.receipts[alice.id] == first.receipts[alice.id]
    assert {:ok, one_read} = RoomServer.mark_read(server, message.id, alice.id)
    assert one_read.status == :delivered
    assert {:ok, all_read} = RoomServer.mark_read(server, message.id, bob.id)
    assert all_read.status == :read
    assert all_read.receipts[alice.id] == one_read.receipts[alice.id]
    assert {:ok, :already_read} = RoomServer.mark_read(server, message.id, bob.id)
    assert [^all_read] = RoomServer.get_messages(server)
    assert {:error, :not_found} = RoomServer.mark_read(server, "missing-message", bob.id)
    assert [^all_read] = RoomServer.get_messages(server)
  end

  test "thread replies keep bounded history and discard context for evicted records", %{room: room, server: server} do
    evicted = message(room, "evicted")
    root = message(room, "root")
    reply = message(room, "reply")
    assert :ok = RoomServer.add_message(server, evicted, %{owned: "evicted-context"})
    assert :ok = RoomServer.add_message(server, root, %{owned: "root-context"})
    assert {:ok, threaded} = GenServer.call(server, {:create_thread, root.id})
    assert threaded.thread_id == root.id
    assert {:ok, ^threaded} = GenServer.call(server, {:create_thread, root.id})
    assert {:ok, threaded_reply} = GenServer.call(server, {:add_thread_reply, root.id, reply})
    assert threaded_reply.thread_id == root.id
    assert [^threaded_reply, ^threaded] = GenServer.call(server, {:get_thread_messages, root.id, []})
    assert [^threaded_reply] = GenServer.call(server, {:get_thread_messages, root.id, [limit: 1]})
    assert RoomServer.message_context(server, evicted.id) == nil
    assert RoomServer.message_context(server, root.id) == %{owned: "root-context"}
    assert RoomServer.message_context(server, reply.id) == nil
    assert map_size(RoomServer.get_state(server).message_contexts) <= 2
    before = RoomServer.get_messages(server)
    assert {:error, :thread_not_found} = GenServer.call(server, {:add_thread_reply, "missing-root", reply})
    assert RoomServer.get_messages(server) == before
    assert {:error, :not_found} = GenServer.call(server, {:create_thread, "missing-root"})
  end

  test "agent removal clears only its assignments and preserves room state", %{server: server} do
    for id <- ["alpha", "beta"],
        do: assert({:ok, %{agent_id: id}} == RoomServer.register_agent(server, %{agent_id: id}))

    assert :ok = RoomServer.assign_thread(server, "alpha-thread", "alpha")
    assert :ok = RoomServer.assign_thread(server, "beta-thread", "beta")
    assert {:error, :unknown_agent} = RoomServer.assign_thread(server, "unknown-thread", "unknown")
    assert {:ok, %{agent_id: "alpha"}} = RoomServer.get_agent(server, "alpha")
    assert :ok = RoomServer.unregister_agent(server, "alpha")
    assert {:error, :not_found} = RoomServer.get_agent(server, "alpha")
    assert [%{agent_id: "beta"}] = RoomServer.list_agents(server)
    assert RoomServer.list_thread_assignments(server) == %{"beta-thread" => "beta"}
    assert RoomServer.thread_assignment(server, "alpha-thread") == nil
  end

  defp participant(id), do: Participant.new(%{id: id, type: :human})

  defp message(room, id),
    do:
      Message.new(%{
        id: id,
        room_id: room.id,
        sender_id: "sender",
        role: :user,
        content: [%{type: :text, text: id}],
        status: :sent
      })
end
