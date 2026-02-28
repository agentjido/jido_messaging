defmodule Jido.Messaging.Persistence.ETSTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Persistence.ETS
  alias Jido.Chat.{LegacyMessage, Participant, Room}

  setup do
    {:ok, state} = ETS.init([])
    {:ok, state: state}
  end

  describe "init/1" do
    test "creates anonymous ETS tables" do
      {:ok, state} = ETS.init([])

      assert is_reference(state.rooms)
      assert is_reference(state.participants)
      assert is_reference(state.messages)
      assert is_reference(state.room_messages)
      assert is_reference(state.room_bindings)
      assert is_reference(state.room_bindings_by_room)
      assert is_reference(state.room_bindings_by_id)
      assert is_reference(state.participant_bindings)
      assert is_reference(state.message_external_ids)
      assert is_reference(state.onboarding_flows)
      assert is_reference(state.bridge_configs)
      assert is_reference(state.routing_policies)
    end
  end

  describe "room operations" do
    test "save_room/2 and get_room/2", %{state: state} do
      room = Room.new(%{type: :direct, name: "Test Room"})

      assert {:ok, saved_room} = ETS.save_room(state, room)
      assert saved_room.id == room.id

      assert {:ok, fetched_room} = ETS.get_room(state, room.id)
      assert fetched_room.id == room.id
      assert fetched_room.name == "Test Room"
    end

    test "get_room/2 returns error for non-existent room", %{state: state} do
      assert {:error, :not_found} = ETS.get_room(state, "non_existent")
    end

    test "delete_room/2 removes room", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      assert :ok = ETS.delete_room(state, room.id)
      assert {:error, :not_found} = ETS.get_room(state, room.id)
    end

    test "list_rooms/2 returns all rooms", %{state: state} do
      room1 = Room.new(%{type: :direct})
      room2 = Room.new(%{type: :group})

      {:ok, _} = ETS.save_room(state, room1)
      {:ok, _} = ETS.save_room(state, room2)

      {:ok, rooms} = ETS.list_rooms(state)
      assert length(rooms) == 2
    end

    test "list_rooms/2 respects limit", %{state: state} do
      for _ <- 1..5, do: ETS.save_room(state, Room.new(%{type: :direct}))

      {:ok, rooms} = ETS.list_rooms(state, limit: 3)
      assert length(rooms) == 3
    end
  end

  describe "participant operations" do
    test "save_participant/2 and get_participant/2", %{state: state} do
      participant = Participant.new(%{type: :human, identity: %{name: "Alice"}})

      assert {:ok, _saved} = ETS.save_participant(state, participant)
      assert {:ok, fetched} = ETS.get_participant(state, participant.id)
      assert fetched.identity.name == "Alice"
    end

    test "get_participant/2 returns error for non-existent", %{state: state} do
      assert {:error, :not_found} = ETS.get_participant(state, "non_existent")
    end

    test "delete_participant/2 removes participant", %{state: state} do
      participant = Participant.new(%{type: :agent})
      {:ok, _} = ETS.save_participant(state, participant)

      assert :ok = ETS.delete_participant(state, participant.id)
      assert {:error, :not_found} = ETS.get_participant(state, participant.id)
    end
  end

  describe "message operations" do
    test "save_message/2 and get_message/2", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      message =
        LegacyMessage.new(%{
          room_id: room.id,
          sender_id: "user_1",
          role: :user,
          content: [%{type: :text, text: "Hello"}]
        })

      assert {:ok, _saved} = ETS.save_message(state, message)
      assert {:ok, fetched} = ETS.get_message(state, message.id)
      assert fetched.content == [%{type: :text, text: "Hello"}]
    end

    test "get_messages/3 returns messages for room", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      msg1 = LegacyMessage.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})
      msg2 = LegacyMessage.new(%{room_id: room.id, sender_id: "u2", role: :user, content: []})

      {:ok, _} = ETS.save_message(state, msg1)
      {:ok, _} = ETS.save_message(state, msg2)

      {:ok, messages} = ETS.get_messages(state, room.id)
      assert length(messages) == 2
    end

    test "get_messages/3 respects limit", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      for i <- 1..10 do
        msg = LegacyMessage.new(%{room_id: room.id, sender_id: "u#{i}", role: :user, content: []})
        ETS.save_message(state, msg)
      end

      {:ok, messages} = ETS.get_messages(state, room.id, limit: 5)
      assert length(messages) == 5
    end

    test "delete_message/2 removes message from index", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      message = LegacyMessage.new(%{room_id: room.id, sender_id: "u1", role: :user, content: []})
      {:ok, _} = ETS.save_message(state, message)

      assert :ok = ETS.delete_message(state, message.id)
      assert {:error, :not_found} = ETS.get_message(state, message.id)

      {:ok, messages} = ETS.get_messages(state, room.id)
      assert messages == []
    end
  end

  describe "external binding operations" do
    test "get_or_create_room_by_external_binding/5 creates room on first call", %{state: state} do
      {:ok, room} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :direct}
        )

      assert room.type == :direct
      assert room.external_bindings == %{telegram: %{"bot_1" => "chat_123"}}
    end

    test "get_or_create_room_by_external_binding/5 returns existing room", %{state: state} do
      {:ok, room1} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :direct}
        )

      {:ok, room2} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :group}
        )

      assert room1.id == room2.id
    end

    test "get_or_create_room_by_external_binding/5 is race-safe under concurrent first access", %{
      state: state
    } do
      results =
        1..100
        |> Task.async_stream(
          fn _idx ->
            ETS.get_or_create_room_by_external_binding(
              state,
              :telegram,
              "bot_1",
              "chat_race",
              %{type: :direct}
            )
          end,
          max_concurrency: 100,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      room_ids =
        results
        |> Enum.map(fn {:ok, room} -> room.id end)
        |> Enum.uniq()

      assert length(room_ids) == 1

      {:ok, rooms} = ETS.list_rooms(state, limit: 1_000)
      assert length(rooms) == 1
    end

    test "get_or_create_room_by_external_binding/5 recovers from stale binding", %{state: state} do
      {:ok, room1} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_stale",
          %{type: :direct}
        )

      :ok = ETS.delete_room(state, room1.id)

      {:ok, room2} =
        ETS.get_or_create_room_by_external_binding(
          state,
          :telegram,
          "bot_1",
          "chat_stale",
          %{type: :direct}
        )

      assert room2.id != room1.id
      assert {:ok, found_room} = ETS.get_room_by_external_binding(state, :telegram, "bot_1", "chat_stale")
      assert found_room.id == room2.id
    end

    test "get_or_create_participant_by_external_id/4 creates participant on first call", %{
      state: state
    } do
      {:ok, participant} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_456",
          %{type: :human, identity: %{name: "Bob"}}
        )

      assert participant.type == :human
      assert participant.external_ids == %{telegram: "user_456"}
    end

    test "get_or_create_participant_by_external_id/4 returns existing participant", %{
      state: state
    } do
      {:ok, p1} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_456",
          %{type: :human}
        )

      {:ok, p2} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_456",
          %{type: :agent}
        )

      assert p1.id == p2.id
    end

    test "get_or_create_participant_by_external_id/4 is race-safe under concurrent first access", %{
      state: state
    } do
      results =
        1..100
        |> Task.async_stream(
          fn _idx ->
            ETS.get_or_create_participant_by_external_id(
              state,
              :telegram,
              "user_race",
              %{type: :human}
            )
          end,
          max_concurrency: 100,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      participant_ids =
        results
        |> Enum.map(fn {:ok, participant} -> participant.id end)
        |> Enum.uniq()

      assert length(participant_ids) == 1
      assert :ets.info(state.participants, :size) == 1
    end

    test "get_or_create_participant_by_external_id/4 recovers from stale binding", %{state: state} do
      {:ok, p1} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_stale",
          %{type: :human}
        )

      :ok = ETS.delete_participant(state, p1.id)

      {:ok, p2} =
        ETS.get_or_create_participant_by_external_id(
          state,
          :telegram,
          "user_stale",
          %{type: :human}
        )

      assert p2.id != p1.id
      assert {:ok, found_participant} = ETS.get_participant(state, p2.id)
      assert found_participant.id == p2.id
    end
  end

  describe "room binding CRUD operations" do
    test "get_room_by_external_binding/4 returns :not_found when no binding exists", %{
      state: state
    } do
      assert {:error, :not_found} =
               ETS.get_room_by_external_binding(state, :telegram, "bot_1", "chat_123")
    end

    test "get_room_by_external_binding/4 finds room after binding created", %{state: state} do
      room = Room.new(%{type: :group, name: "Test"})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, _binding} =
        ETS.create_room_binding(state, room.id, :telegram, "bot_1", "chat_123", %{})

      {:ok, found_room} = ETS.get_room_by_external_binding(state, :telegram, "bot_1", "chat_123")
      assert found_room.id == room.id
    end

    test "create_room_binding/6 creates a RoomBinding struct", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, binding} =
        ETS.create_room_binding(state, room.id, :discord, "guild_1", "channel_456", %{
          direction: :both
        })

      assert binding.room_id == room.id
      assert binding.channel == :discord
      assert binding.bridge_id == "guild_1"
      assert binding.external_room_id == "channel_456"
      assert binding.direction == :both
      assert String.starts_with?(binding.id, "bind_")
    end

    test "create_room_binding/6 uses canonical bridge_id from function arguments", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, binding} =
        ETS.create_room_binding(state, room.id, :telegram, "legacy_inst", "chat_999", %{
          bridge_id: "bridge_telegram_primary"
        })

      assert binding.bridge_id == "legacy_inst"

      assert {:ok, by_bridge_room} =
               ETS.get_room_by_external_binding(state, :telegram, "legacy_inst", "chat_999")

      assert by_bridge_room.id == room.id
    end

    test "list_room_bindings/2 returns all bindings for a room", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, _} = ETS.create_room_binding(state, room.id, :telegram, "bot_1", "chat_1", %{})
      {:ok, _} = ETS.create_room_binding(state, room.id, :discord, "guild_1", "channel_1", %{})

      {:ok, bindings} = ETS.list_room_bindings(state, room.id)
      assert length(bindings) == 2

      channels = Enum.map(bindings, & &1.channel) |> Enum.sort()
      assert channels == [:discord, :telegram]
    end

    test "list_room_bindings/2 returns empty list when no bindings", %{state: state} do
      room = Room.new(%{type: :direct})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, bindings} = ETS.list_room_bindings(state, room.id)
      assert bindings == []
    end

    test "delete_room_binding/2 removes binding", %{state: state} do
      room = Room.new(%{type: :group})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, binding} =
        ETS.create_room_binding(state, room.id, :telegram, "bot_1", "chat_123", %{})

      assert :ok = ETS.delete_room_binding(state, binding.id)

      {:ok, bindings} = ETS.list_room_bindings(state, room.id)
      assert bindings == []

      assert {:error, :not_found} =
               ETS.get_room_by_external_binding(state, :telegram, "bot_1", "chat_123")
    end

    test "delete_room_binding/2 returns error for non-existent binding", %{state: state} do
      assert {:error, :not_found} = ETS.delete_room_binding(state, "bind_nonexistent")
    end

    test "one room can have multiple external bindings", %{state: state} do
      room = Room.new(%{type: :group, name: "Shared Room"})
      {:ok, _} = ETS.save_room(state, room)

      {:ok, _} = ETS.create_room_binding(state, room.id, :telegram, "bot_1", "tg_chat", %{})
      {:ok, _} = ETS.create_room_binding(state, room.id, :discord, "guild_1", "dc_channel", %{})

      {:ok, tg_room} = ETS.get_room_by_external_binding(state, :telegram, "bot_1", "tg_chat")
      {:ok, dc_room} = ETS.get_room_by_external_binding(state, :discord, "guild_1", "dc_channel")

      assert tg_room.id == room.id
      assert dc_room.id == room.id
      assert tg_room.id == dc_room.id
    end
  end

  describe "directory operations" do
    test "directory_search/4 and directory_lookup/4 return consistent participant results", %{
      state: state
    } do
      {:ok, participant_a} =
        ETS.save_participant(
          state,
          Participant.new(%{
            type: :human,
            identity: %{name: "Alex Rivera"},
            external_ids: %{slack: "alex_1"}
          })
        )

      {:ok, participant_b} =
        ETS.save_participant(
          state,
          Participant.new(%{
            type: :human,
            identity: %{name: "Alex Kim"},
            external_ids: %{slack: "alex_2"}
          })
        )

      assert {:ok, matches} = ETS.directory_search(state, :participant, %{name: "alex"}, [])
      assert Enum.map(matches, & &1.id) == Enum.sort([participant_a.id, participant_b.id])

      assert {:error, {:ambiguous, ambiguous_matches}} =
               ETS.directory_lookup(state, :participant, %{name: "alex"}, [])

      assert Enum.map(ambiguous_matches, & &1.id) == Enum.map(matches, & &1.id)

      assert {:ok, found} =
               ETS.directory_lookup(
                 state,
                 :participant,
                 %{channel: :slack, external_id: "alex_2"},
                 []
               )

      assert found.id == participant_b.id
    end

    test "directory search supports room lookup by external binding", %{state: state} do
      room = Room.new(%{type: :group, name: "Ops Room"})
      {:ok, _} = ETS.save_room(state, room)
      {:ok, _binding} = ETS.create_room_binding(state, room.id, :discord, "guild_1", "chan_22", %{})

      assert {:ok, [found_room]} =
               ETS.directory_search(
                 state,
                 :room,
                 %{channel: :discord, bridge_id: "guild_1", external_id: "chan_22"},
                 []
               )

      assert found_room.id == room.id
    end
  end

  describe "onboarding persistence operations" do
    test "save_onboarding/2 and get_onboarding/2 round trip flow state", %{state: state} do
      flow = %{
        onboarding_id: "onboarding_1",
        status: :started,
        request: %{source: "test"},
        transitions: [],
        idempotency: %{},
        side_effects: [],
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert {:ok, ^flow} = ETS.save_onboarding(state, flow)
      assert {:ok, loaded_flow} = ETS.get_onboarding(state, "onboarding_1")
      assert loaded_flow.onboarding_id == "onboarding_1"
      assert loaded_flow.request == %{source: "test"}
    end
  end
end
