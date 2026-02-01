defmodule JidoMessaging.RoomServerFeaturesTest do
  @moduledoc """
  Tests for RoomServer features: threads, reactions, receipts, typing, presence.
  """
  use ExUnit.Case, async: true

  alias JidoMessaging.{Room, Message, Participant, RoomServer}

  setup do
    start_supervised!(JidoMessaging.TestMessaging)
    room = Room.new(%{type: :group, name: "Test Room"})
    {:ok, _pid} = RoomServer.start_link(room: room, instance_module: JidoMessaging.TestMessaging)
    server = RoomServer.via_tuple(JidoMessaging.TestMessaging, room.id)

    participant1 = Participant.new(%{type: :human, identity: %{name: "Alice"}})
    participant2 = Participant.new(%{type: :human, identity: %{name: "Bob"}})
    :ok = RoomServer.add_participant(server, participant1)
    :ok = RoomServer.add_participant(server, participant2)

    message =
      Message.new(%{
        room_id: room.id,
        sender_id: participant1.id,
        role: :user,
        content: [%{type: :text, text: "Hello!"}]
      })

    :ok = RoomServer.add_message(server, message)

    {:ok, server: server, room: room, p1: participant1, p2: participant2, message: message}
  end

  describe "threads" do
    test "create_thread marks message as thread root", %{server: server, message: message} do
      {:ok, updated} = RoomServer.create_thread(server, message.id)
      assert updated.thread_root_id == message.id
    end

    test "create_thread is idempotent", %{server: server, message: message} do
      {:ok, _} = RoomServer.create_thread(server, message.id)
      {:ok, updated} = RoomServer.create_thread(server, message.id)
      assert updated.thread_root_id == message.id
    end

    test "add_thread_reply adds reply to thread", %{server: server, room: room, message: message, p2: p2} do
      {:ok, _} = RoomServer.create_thread(server, message.id)

      reply =
        Message.new(%{
          room_id: room.id,
          sender_id: p2.id,
          role: :user,
          content: [%{type: :text, text: "Thread reply!"}]
        })

      {:ok, added_reply} = RoomServer.add_thread_reply(server, message.id, reply)
      assert added_reply.thread_root_id == message.id
    end

    test "add_thread_reply fails if thread doesn't exist", %{server: server, room: room, p2: p2} do
      reply =
        Message.new(%{
          room_id: room.id,
          sender_id: p2.id,
          role: :user,
          content: [%{type: :text, text: "Reply"}]
        })

      assert {:error, :thread_not_found} = RoomServer.add_thread_reply(server, "nonexistent", reply)
    end

    test "get_thread_messages returns only thread messages", %{server: server, room: room, message: message, p2: p2} do
      {:ok, _} = RoomServer.create_thread(server, message.id)

      reply1 = Message.new(%{room_id: room.id, sender_id: p2.id, role: :user, content: [%{type: :text, text: "R1"}]})
      reply2 = Message.new(%{room_id: room.id, sender_id: p2.id, role: :user, content: [%{type: :text, text: "R2"}]})

      {:ok, _} = RoomServer.add_thread_reply(server, message.id, reply1)
      {:ok, _} = RoomServer.add_thread_reply(server, message.id, reply2)

      thread_msgs = RoomServer.get_thread_messages(server, message.id)
      assert length(thread_msgs) == 3
      assert Enum.all?(thread_msgs, &(&1.thread_root_id == message.id))
    end
  end

  describe "reactions" do
    test "add_reaction adds reaction to message", %{server: server, message: message, p1: p1} do
      {:ok, updated} = RoomServer.add_reaction(server, message.id, p1.id, "👍")
      assert updated.reactions["👍"] == [p1.id]
    end

    test "add_reaction from multiple participants", %{server: server, message: message, p1: p1, p2: p2} do
      {:ok, _} = RoomServer.add_reaction(server, message.id, p1.id, "👍")
      {:ok, updated} = RoomServer.add_reaction(server, message.id, p2.id, "👍")

      assert p1.id in updated.reactions["👍"]
      assert p2.id in updated.reactions["👍"]
    end

    test "add_reaction is idempotent", %{server: server, message: message, p1: p1} do
      {:ok, _} = RoomServer.add_reaction(server, message.id, p1.id, "👍")
      {:ok, :already_exists} = RoomServer.add_reaction(server, message.id, p1.id, "👍")
    end

    test "remove_reaction removes reaction", %{server: server, message: message, p1: p1} do
      {:ok, _} = RoomServer.add_reaction(server, message.id, p1.id, "👍")
      {:ok, updated} = RoomServer.remove_reaction(server, message.id, p1.id, "👍")

      refute Map.has_key?(updated.reactions, "👍")
    end

    test "remove_reaction handles not found", %{server: server, message: message, p1: p1} do
      {:ok, :not_found} = RoomServer.remove_reaction(server, message.id, p1.id, "👍")
    end

    test "multiple reactions on same message", %{server: server, message: message, p1: p1, p2: p2} do
      {:ok, _} = RoomServer.add_reaction(server, message.id, p1.id, "👍")
      {:ok, _} = RoomServer.add_reaction(server, message.id, p2.id, "❤️")
      {:ok, updated} = RoomServer.add_reaction(server, message.id, p1.id, "😂")

      assert Map.has_key?(updated.reactions, "👍")
      assert Map.has_key?(updated.reactions, "❤️")
      assert Map.has_key?(updated.reactions, "😂")
    end
  end

  describe "read receipts" do
    test "mark_delivered updates receipt", %{server: server, message: message, p2: p2} do
      {:ok, updated} = RoomServer.mark_delivered(server, message.id, p2.id)

      assert Map.has_key?(updated.receipts, p2.id)
      assert updated.receipts[p2.id].delivered_at != nil
    end

    test "mark_delivered is idempotent", %{server: server, message: message, p2: p2} do
      {:ok, _} = RoomServer.mark_delivered(server, message.id, p2.id)
      {:ok, :already_delivered} = RoomServer.mark_delivered(server, message.id, p2.id)
    end

    test "mark_read updates receipt", %{server: server, message: message, p2: p2} do
      {:ok, updated} = RoomServer.mark_read(server, message.id, p2.id)

      assert Map.has_key?(updated.receipts, p2.id)
      assert updated.receipts[p2.id].read_at != nil
      assert updated.receipts[p2.id].delivered_at != nil
    end

    test "mark_read is idempotent", %{server: server, message: message, p2: p2} do
      {:ok, _} = RoomServer.mark_read(server, message.id, p2.id)
      {:ok, :already_read} = RoomServer.mark_read(server, message.id, p2.id)
    end

    test "message status updates to :delivered when all recipients delivered", %{
      server: server,
      message: message,
      p2: p2
    } do
      {:ok, updated} = RoomServer.mark_delivered(server, message.id, p2.id)
      assert updated.status == :delivered
    end

    test "message status updates to :read when all recipients read", %{server: server, message: message, p2: p2} do
      {:ok, updated} = RoomServer.mark_read(server, message.id, p2.id)
      assert updated.status == :read
    end
  end

  describe "presence" do
    test "update_presence changes participant presence", %{server: server, p1: p1} do
      :ok = RoomServer.update_presence(server, p1.id, :online)

      participants = RoomServer.get_participants(server)
      updated = Enum.find(participants, &(&1.id == p1.id))
      assert updated.presence == :online
    end

    test "update_presence returns error for unknown participant", %{server: server} do
      assert {:error, :not_found} = RoomServer.update_presence(server, "unknown", :online)
    end
  end

  describe "typing" do
    test "set_typing starts typing indicator", %{server: server, p1: p1} do
      :ok = RoomServer.set_typing(server, p1.id, true)

      typing = RoomServer.get_typing(server)
      assert Enum.any?(typing, &(&1.participant_id == p1.id))
    end

    test "set_typing stops typing indicator", %{server: server, p1: p1} do
      :ok = RoomServer.set_typing(server, p1.id, true)
      :ok = RoomServer.set_typing(server, p1.id, false)

      typing = RoomServer.get_typing(server)
      refute Enum.any?(typing, &(&1.participant_id == p1.id))
    end

    test "set_typing with thread_root_id", %{server: server, p1: p1, message: message} do
      :ok = RoomServer.set_typing(server, p1.id, true, thread_root_id: message.id)

      typing = RoomServer.get_typing(server)
      typing_entry = Enum.find(typing, &(&1.participant_id == p1.id))
      assert typing_entry.thread_root_id == message.id
    end

    test "multiple participants typing", %{server: server, p1: p1, p2: p2} do
      :ok = RoomServer.set_typing(server, p1.id, true)
      :ok = RoomServer.set_typing(server, p2.id, true)

      typing = RoomServer.get_typing(server)
      assert length(typing) == 2
    end
  end
end
