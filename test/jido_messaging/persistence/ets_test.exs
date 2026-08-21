defmodule Jido.Messaging.Persistence.ETSTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{Message, Thread}
  alias Jido.Messaging.Persistence.ETS

  setup do
    {:ok, state} = ETS.init([])
    {:ok, state: state}
  end

  describe "init/1" do
    test "creates the backing ETS tables" do
      {:ok, state} = ETS.init([])

      assert is_reference(state.rooms)
      assert is_reference(state.participants)
      assert is_reference(state.messages)
      assert is_reference(state.threads)
      assert is_reference(state.room_messages)
      assert is_reference(state.thread_messages)
      assert is_reference(state.room_bindings)
      assert is_reference(state.participant_bindings)
      assert is_reference(state.message_external_ids)
    end
  end

  describe "room operations" do
    test "save_room/2 and get_room/2 round-trip rooms", %{state: state} do
      room = Room.new(%{type: :direct, name: "Test Room"})

      assert {:ok, saved_room} = ETS.save_room(state, room)
      assert saved_room.id == room.id
      assert ETS.get_room(state, room.id) == {:ok, room}
    end

    test "delete_room/2 removes the room and its thread indexes", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      thread = Thread.new(%{room_id: room.id, external_thread_id: "thread-1"})
      {:ok, _} = ETS.save_thread(state, thread)

      assert :ok = ETS.delete_room(state, room.id)
      assert ETS.get_room(state, room.id) == {:error, :not_found}
      assert ETS.list_threads(state, room.id) == {:ok, []}
    end
  end

  describe "participant operations" do
    test "save_participant/2 and get_participant/2 round-trip participants", %{state: state} do
      participant = Participant.new(%{type: :human, identity: %{name: "Alice"}})

      assert {:ok, _saved} = ETS.save_participant(state, participant)
      assert {:ok, fetched} = ETS.get_participant(state, participant.id)
      assert fetched.identity.name == "Alice"
    end

    test "scopes provider identities by bridge and supports explicit links", %{state: state} do
      assert {:ok, first} =
               ETS.get_or_create_participant_by_external_binding(
                 state,
                 :slack,
                 "workspace-one",
                 "user-1",
                 %{type: :human, identity: %{name: "First"}}
               )

      assert {:ok, second} =
               ETS.get_or_create_participant_by_external_binding(
                 state,
                 :slack,
                 "workspace-two",
                 "user-1",
                 %{type: :human, identity: %{name: "Second"}}
               )

      refute first.id == second.id

      assert :ok =
               ETS.bind_participant_external_id(
                 state,
                 first.id,
                 :slack,
                 "workspace-three",
                 "user-linked"
               )

      assert {:ok, linked} =
               ETS.get_or_create_participant_by_external_binding(
                 state,
                 :slack,
                 "workspace-three",
                 "user-linked",
                 %{}
               )

      assert linked.id == first.id

      assert {:error, {:external_identity_conflict, first_id}} =
               ETS.bind_participant_external_id(
                 state,
                 second.id,
                 :slack,
                 "workspace-three",
                 "user-linked"
               )

      assert first_id == first.id
    end
  end

  describe "message operations" do
    test "save_message/2 and get_message/2 round-trip messages", %{state: state} do
      room = persist_room!(state)

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello"}]
        })

      assert {:ok, _saved} = ETS.save_message(state, message)
      assert {:ok, fetched} = ETS.get_message(state, message.id)
      assert fetched.content == [%{type: :text, text: "Hello"}]
    end

    test "get_messages/3 supports room-wide history and thread filtering", %{state: state} do
      room = persist_room!(state)
      thread = persist_thread!(state, %{room_id: room.id, external_thread_id: "thread-1"})

      root =
        Message.new(%{
          room_id: room.id,
          sender_id: "u1",
          role: :user,
          content: [%{type: :text, text: "root"}],
          thread_id: thread.id
        })

      reply =
        Message.new(%{
          room_id: room.id,
          sender_id: "u2",
          role: :assistant,
          content: [%{type: :text, text: "reply"}],
          thread_id: thread.id
        })

      other =
        Message.new(%{
          room_id: room.id,
          sender_id: "u3",
          role: :user,
          content: [%{type: :text, text: "other"}]
        })

      {:ok, _} = ETS.save_message(state, root)
      {:ok, _} = ETS.save_message(state, reply)
      {:ok, _} = ETS.save_message(state, other)

      assert {:ok, room_messages} = ETS.get_messages(state, room.id)
      assert Enum.map(room_messages, & &1.id) == [root.id, reply.id, other.id]

      assert {:ok, thread_messages} = ETS.get_messages(state, room.id, thread_id: thread.id)
      assert Enum.map(thread_messages, & &1.id) == [root.id, reply.id]
    end

    test "get_messages/3 paginates before and after a stable message cursor", %{state: state} do
      room = persist_room!(state)
      messages = pagination_messages(room.id)
      Enum.each(messages, &ETS.save_message(state, &1))

      assert {:ok, latest} = ETS.get_messages(state, room.id, limit: 2)
      assert Enum.map(latest, & &1.id) == ["message:3", "message:4"]

      assert {:ok, older} = ETS.get_messages(state, room.id, before: "message:3", limit: 2)
      assert Enum.map(older, & &1.id) == ["message:1", "message:2"]

      assert {:ok, newer} = ETS.get_messages(state, room.id, after: "message:2", limit: 2)
      assert Enum.map(newer, & &1.id) == ["message:3", "message:4"]

      assert {:error, :cursor_not_found} = ETS.get_messages(state, room.id, before: "missing")

      assert {:error, :invalid_cursor_options} =
               ETS.get_messages(state, room.id, before: "message:3", after: "message:2")
    end

    test "get_messages/3 traverses boundaries without repeats and rejects stale or out-of-scope cursors", %{
      state: state
    } do
      room = persist_room!(state)
      messages = pagination_messages(room.id)
      Enum.each(messages, &ETS.save_message(state, &1))

      assert {:ok, first_page} = ETS.get_messages(state, room.id, limit: 2)
      assert {:ok, second_page} = ETS.get_messages(state, room.id, before: hd(first_page).id, limit: 2)
      assert Enum.map(second_page ++ first_page, & &1.id) == Enum.map(messages, & &1.id)

      assert {:ok, []} = ETS.get_messages(state, room.id, before: hd(messages).id, limit: 2)
      assert {:ok, []} = ETS.get_messages(state, room.id, after: List.last(messages).id, limit: 2)

      assert :ok = ETS.delete_message(state, "message:2")
      assert {:error, :cursor_not_found} = ETS.get_messages(state, room.id, after: "message:2")

      thread_cursor = pagination_message("message:thread-cursor", room.id, hd(messages).inserted_at, "thread:one")
      thread_message = pagination_message("message:thread", room.id, List.last(messages).inserted_at, "thread:one")
      assert {:ok, _message} = ETS.save_message(state, thread_cursor)
      assert {:ok, _message} = ETS.save_message(state, thread_message)

      assert {:ok, [^thread_message]} =
               ETS.get_messages(state, room.id, thread_id: "thread:one", after: thread_cursor.id)

      assert {:error, :cursor_not_found} =
               ETS.get_messages(state, room.id, thread_id: "thread:other", after: thread_cursor.id)
    end

    test "get_messages/3 gives deterministic order to imported messages without timestamps", %{state: state} do
      room = persist_room!(state)
      missing_timestamp = pagination_message("message:missing-time", room.id, nil)
      timestamped = pagination_message("message:timestamped", room.id, ~U[2026-01-01 00:00:00Z])

      assert {:ok, _message} = ETS.save_message(state, timestamped)
      assert {:ok, _message} = ETS.save_message(state, missing_timestamp)

      assert {:ok, [^missing_timestamp, ^timestamped]} = ETS.get_messages(state, room.id)
      assert {:ok, [^timestamped]} = ETS.get_messages(state, room.id, after: missing_timestamp.id)
    end

    test "delete_message/2 removes the room and thread indexes", %{state: state} do
      room = persist_room!(state)
      thread = persist_thread!(state, %{room_id: room.id, external_thread_id: "thread-1"})

      message =
        Message.new(%{
          room_id: room.id,
          sender_id: "u1",
          role: :user,
          content: [%{type: :text, text: "Hello"}],
          thread_id: thread.id
        })

      {:ok, _} = ETS.save_message(state, message)

      assert :ok = ETS.delete_message(state, message.id)
      assert ETS.get_message(state, message.id) == {:error, :not_found}
      assert ETS.get_messages(state, room.id) == {:ok, []}
      assert ETS.get_messages(state, room.id, thread_id: thread.id) == {:ok, []}
    end
  end

  describe "thread operations" do
    test "save_thread/2 and get_thread/2 round-trip threads", %{state: state} do
      room = persist_room!(state)
      thread = Thread.new(%{room_id: room.id, external_thread_id: "thread-1"})

      assert {:ok, saved_thread} = ETS.save_thread(state, thread)
      assert saved_thread.id == thread.id
      assert ETS.get_thread(state, thread.id) == {:ok, thread}
    end

    test "finds threads by external id and root message id", %{state: state} do
      room = persist_room!(state)

      thread =
        Thread.new(%{
          room_id: room.id,
          external_thread_id: "thread-1",
          root_message_id: "root-1",
          root_external_message_id: "ext-root-1"
        })

      {:ok, _} = ETS.save_thread(state, thread)

      assert ETS.get_thread_by_external_id(state, room.id, "thread-1") == {:ok, thread}
      assert ETS.get_thread_by_root_message(state, room.id, "root-1") == {:ok, thread}
    end

    test "list_threads/3 returns room threads newest first and respects limit", %{state: state} do
      room = persist_room!(state)

      older = persist_thread!(state, %{room_id: room.id, external_thread_id: "thread-1"})
      newer = persist_thread!(state, %{room_id: room.id, external_thread_id: "thread-2"})

      assert {:ok, [listed_older, listed_newer]} = ETS.list_threads(state, room.id)
      assert listed_older.id == older.id
      assert listed_newer.id == newer.id

      assert {:ok, [limited]} = ETS.list_threads(state, room.id, limit: 1)
      assert limited.id == older.id
    end
  end

  defp persist_room!(state) do
    room = Room.new(%{type: :direct})
    {:ok, room} = ETS.save_room(state, room)
    room
  end

  defp persist_thread!(state, attrs) do
    thread = Thread.new(attrs)
    {:ok, thread} = ETS.save_thread(state, thread)
    thread
  end

  defp pagination_messages(room_id) do
    base = ~U[2026-01-01 00:00:00.000000Z]

    [
      pagination_message("message:1", room_id, base),
      pagination_message("message:2", room_id, DateTime.add(base, 1, :second)),
      pagination_message("message:3", room_id, DateTime.add(base, 1, :second)),
      pagination_message("message:4", room_id, DateTime.add(base, 2, :second))
    ]
  end

  defp pagination_message(id, room_id, inserted_at, thread_id \\ nil) do
    Message.new(%{
      id: id,
      room_id: room_id,
      sender_id: "user:cursor",
      role: :user,
      content: [%{type: :text, text: id}],
      inserted_at: inserted_at,
      thread_id: thread_id
    })
  end
end
