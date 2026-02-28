defmodule Jido.Messaging.MultiRoomIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for multi-room, multi-participant scenarios.

  Run with: mix test --only integration
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Jido.Chat.Content.Text
  alias Jido.Messaging.{Ingest, Deliver, RoomServer, RoomSupervisor, PubSub}

  defmodule MockTelegramChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(%{message: msg}) do
      {:ok,
       %{
         external_room_id: msg.chat_id,
         external_user_id: msg.user_id,
         text: msg.text,
         username: msg.username,
         display_name: msg.display_name,
         external_message_id: msg.message_id,
         timestamp: msg.date,
         chat_type: msg[:chat_type] || :group
       }}
    end

    @impl true
    def send_message(chat_id, text, _opts) do
      {:ok, %{message_id: System.unique_integer([:positive]), chat_id: chat_id, text: text}}
    end
  end

  setup do
    if PubSub.pubsub_available?() do
      start_supervised!({Phoenix.PubSub, name: Jido.Messaging.TestPubSub})
      start_supervised!(Jido.Messaging.TestMessagingWithPubSub)
      Jido.Messaging.TestMessagingWithPubSub.clear_dedupe()
      {:ok, messaging: Jido.Messaging.TestMessagingWithPubSub, pubsub_enabled: true}
    else
      start_supervised!(Jido.Messaging.TestMessaging)
      Jido.Messaging.TestMessaging.clear_dedupe()
      {:ok, messaging: Jido.Messaging.TestMessaging, pubsub_enabled: false}
    end
  end

  defp ingest!(messaging, chat_id, user_id, text, msg_id, opts \\ []) do
    incoming = %{
      external_room_id: chat_id,
      external_user_id: user_id,
      text: text,
      external_message_id: msg_id,
      username: Keyword.get(opts, :username, user_id),
      display_name: Keyword.get(opts, :display_name, user_id),
      chat_type: Keyword.get(opts, :chat_type, :group)
    }

    {:ok, message, context} =
      Ingest.ingest_incoming(messaging, MockTelegramChannel, "bot_1", incoming)

    {message, context}
  end

  defp reply!(messaging, incoming_message, context, text) do
    {:ok, reply} = Deliver.deliver_outgoing(messaging, incoming_message, text, context)
    reply
  end

  describe "multi-room multi-participant lifecycle" do
    test "full scenario with concurrent messaging and cross-room participants", %{
      messaging: messaging,
      pubsub_enabled: pubsub_enabled
    } do
      # Scenario:
      # - Room A: "project_alpha" with participants alice + bob
      # - Room B: "project_beta" with participants alice + carol
      # - Alice is in both rooms (cross-room participant)

      # 1) Room lifecycle: rooms are created on first ingest per external_room_id
      {msg_a1, ctx_a1} =
        ingest!(messaging, "project_alpha", "alice_ext", "Hi Alpha team", 1,
          username: "alice",
          display_name: "Alice"
        )

      {msg_b1, ctx_b1} =
        ingest!(messaging, "project_beta", "alice_ext", "Hi Beta team", 2,
          username: "alice",
          display_name: "Alice"
        )

      room_a = ctx_a1.room
      room_b = ctx_b1.room
      assert room_a.id != room_b.id

      # 2) Cross-room participant identity: Alice should map to same participant record
      assert ctx_a1.participant.id == ctx_b1.participant.id

      # 3) Room listing: both rooms should exist and be discoverable
      {:ok, rooms} = messaging.list_rooms()
      room_ids = Enum.map(rooms, & &1.id)
      assert room_a.id in room_ids
      assert room_b.id in room_ids

      # 4) PubSub subscription for both rooms (if available)
      # Note: Phase 6 removed PubSub for message_added/participant_joined/left
      # These events now use Signal Bus instead
      if pubsub_enabled do
        assert PubSub.configured?(messaging)
        :ok = messaging.subscribe(room_a.id)
        :ok = messaging.subscribe(room_b.id)
      end

      # 5) Add more participants
      {_msg_a2, ctx_a2} =
        ingest!(messaging, "project_alpha", "bob_ext", "Bob joined Alpha", 3,
          username: "bob",
          display_name: "Bob"
        )

      # Phase 6: PubSub assertions removed - these events use Signal Bus now
      # See room_server_signals_test.exs and agent_runner_signals_test.exs

      {_msg_b2, ctx_b2} =
        ingest!(messaging, "project_beta", "carol_ext", "Carol joined Beta", 4,
          username: "carol",
          display_name: "Carol"
        )

      # Phase 6: PubSub assertions removed - these events use Signal Bus now

      # 6) Full flow: ingest → deliver (and resulting stored messages)
      reply_a1 = reply!(messaging, msg_a1, ctx_a1, "Bot: welcome to Alpha")
      reply_b1 = reply!(messaging, msg_b1, ctx_b1, "Bot: welcome to Beta")

      assert reply_a1.reply_to_id == msg_a1.id
      assert reply_a1.status == :sent
      assert [%Text{text: "Bot: welcome to Alpha"}] = reply_a1.content

      assert reply_b1.reply_to_id == msg_b1.id
      assert reply_b1.status == :sent
      assert [%Text{text: "Bot: welcome to Beta"}] = reply_b1.content

      # Phase 6: PubSub assertions removed - message_added uses Signal Bus now
      # if pubsub_enabled do
      #   reply_a1_id = reply_a1.id
      #   reply_b1_id = reply_b1.id
      #   assert_receive {:message_added, %Jido.Chat.LegacyMessage{id: ^reply_a1_id}}, 1_000
      #   assert_receive {:message_added, %Jido.Chat.LegacyMessage{id: ^reply_b1_id}}, 1_000
      # end
      _ = pubsub_enabled

      # 7) Verify RoomServer state: participants tracked per room
      pid_a = RoomServer.whereis(messaging, room_a.id)
      pid_b = RoomServer.whereis(messaging, room_b.id)
      assert is_pid(pid_a)
      assert is_pid(pid_b)

      participants_a = RoomServer.get_participants(pid_a) |> Enum.map(& &1.id)
      participants_b = RoomServer.get_participants(pid_b) |> Enum.map(& &1.id)

      # Alice in Alpha
      assert ctx_a1.participant.id in participants_a
      # Bob in Alpha
      assert ctx_a2.participant.id in participants_a
      # Alice in Beta
      assert ctx_b1.participant.id in participants_b
      # Carol in Beta
      assert ctx_b2.participant.id in participants_b

      # 8) Verify message history in RoomServer
      messages_a = RoomServer.get_messages(pid_a)
      messages_b = RoomServer.get_messages(pid_b)

      # Room A should have: msg_a1 (Alice), msg_a2 (Bob), reply_a1 (bot)
      assert length(messages_a) >= 3
      # Room B should have: msg_b1 (Alice), msg_b2 (Carol), reply_b1 (bot)
      assert length(messages_b) >= 3

      # 9) RoomSupervisor lifecycle checks
      assert RoomSupervisor.count_rooms(messaging) >= 2
      running_room_ids = messaging.list_room_servers() |> Enum.map(fn {room_id, _pid} -> room_id end)
      assert room_a.id in running_room_ids
      assert room_b.id in running_room_ids
    end

    test "concurrent message handling across multiple rooms", %{messaging: messaging} do
      # Set up two rooms first
      {_msg_a, ctx_a} =
        ingest!(messaging, "concurrent_alpha", "user1", "Initial Alpha", 100,
          username: "user1",
          display_name: "User One"
        )

      {_msg_b, ctx_b} =
        ingest!(messaging, "concurrent_beta", "user2", "Initial Beta", 101,
          username: "user2",
          display_name: "User Two"
        )

      room_a_id = ctx_a.room.id
      room_b_id = ctx_b.room.id

      # Burst of concurrent messages across both rooms
      burst =
        [
          {:a, "user1", "Alpha burst 1"},
          {:a, "user3", "Alpha burst 2"},
          {:a, "user1", "Alpha burst 3"},
          {:b, "user2", "Beta burst 1"},
          {:b, "user4", "Beta burst 2"},
          {:b, "user2", "Beta burst 3"},
          {:a, "user5", "Alpha burst 4"},
          {:b, "user6", "Beta burst 4"}
        ]
        |> Stream.with_index(10_000)

      results =
        burst
        |> Task.async_stream(
          fn {{which, user, text}, idx} ->
            chat = if which == :a, do: "concurrent_alpha", else: "concurrent_beta"
            {msg, ctx} = ingest!(messaging, chat, user, text, idx, username: user, display_name: user)
            _reply = reply!(messaging, msg, ctx, "Bot ack: #{text}")
            {msg.room_id, msg.id}
          end,
          max_concurrency: 8,
          timeout: 10_000
        )
        |> Enum.to_list()

      # All operations should succeed
      assert Enum.all?(results, fn
               {:ok, {_room_id, _msg_id}} -> true
               _ -> false
             end)

      # Verify persisted messages (each burst item = 2 messages: user + assistant reply)
      {:ok, msgs_a} = messaging.list_messages(room_a_id)
      {:ok, msgs_b} = messaging.list_messages(room_b_id)

      # Alpha: 1 initial + 4 burst messages + 4 replies = 9 minimum
      assert length(msgs_a) >= 9
      # Beta: 1 initial + 4 burst messages + 4 replies = 9 minimum
      assert length(msgs_b) >= 9

      # Verify room servers are still healthy
      pid_a = RoomServer.whereis(messaging, room_a_id)
      pid_b = RoomServer.whereis(messaging, room_b_id)
      assert is_pid(pid_a)
      assert is_pid(pid_b)
    end

    test "participant identity is consistent across rooms and messages", %{messaging: messaging} do
      # Alice sends messages to three different rooms
      {_msg1, ctx1} =
        ingest!(messaging, "room_x", "alice_unified", "Hello X", 200,
          username: "alice",
          display_name: "Alice Wonderland"
        )

      {_msg2, ctx2} =
        ingest!(messaging, "room_y", "alice_unified", "Hello Y", 201,
          username: "alice",
          display_name: "Alice Wonderland"
        )

      {_msg3, ctx3} =
        ingest!(messaging, "room_z", "alice_unified", "Hello Z", 202,
          username: "alice",
          display_name: "Alice Wonderland"
        )

      # Same participant ID across all rooms
      assert ctx1.participant.id == ctx2.participant.id
      assert ctx2.participant.id == ctx3.participant.id

      # But different room IDs
      assert ctx1.room.id != ctx2.room.id
      assert ctx2.room.id != ctx3.room.id
      assert ctx1.room.id != ctx3.room.id

      # Participant appears in each room's participant list
      for ctx <- [ctx1, ctx2, ctx3] do
        pid = RoomServer.whereis(messaging, ctx.room.id)
        participants = RoomServer.get_participants(pid) |> Enum.map(& &1.id)
        assert ctx.participant.id in participants
      end
    end

    @tag :skip
    @tag :phase6_deprecated
    test "pubsub events are room-scoped", %{messaging: messaging, pubsub_enabled: pubsub_enabled} do
      # Phase 6: This test is deprecated - message_added/participant_joined/left
      # events now use Signal Bus instead of PubSub.
      # The room scoping behavior is still valid but needs to be tested via Signal Bus.
      unless pubsub_enabled do
        # Skip this test if PubSub is not available
        assert true
      else
        # Subscribe only to room_subscribed
        {_msg_sub, ctx_sub} =
          ingest!(messaging, "room_subscribed", "user_a", "Subscribed room msg", 300,
            username: "user_a",
            display_name: "User A"
          )

        {_msg_unsub, _ctx_unsub} =
          ingest!(messaging, "room_unsubscribed", "user_b", "Unsubscribed room msg", 301,
            username: "user_b",
            display_name: "User B"
          )

        # Subscribe only to one room
        :ok = messaging.subscribe(ctx_sub.room.id)

        # Send message to subscribed room
        {msg_sub2, _ctx_sub2} =
          ingest!(messaging, "room_subscribed", "user_c", "Another subscribed msg", 302,
            username: "user_c",
            display_name: "User C"
          )

        # Send message to unsubscribed room
        {_msg_unsub2, _ctx_unsub2} =
          ingest!(messaging, "room_unsubscribed", "user_d", "Another unsubscribed msg", 303,
            username: "user_d",
            display_name: "User D"
          )

        # Should receive events only from subscribed room
        msg_sub2_id = msg_sub2.id
        assert_receive {:message_added, %Jido.Chat.LegacyMessage{id: ^msg_sub2_id}}, 1_000
        assert_receive {:participant_joined, _}, 1_000

        # Drain any remaining events for subscribed room
        receive do
          {:participant_joined, _} -> :ok
        after
          100 -> :ok
        end

        # We should not see any more events (unsubscribed room events don't reach us)
        refute_receive {:message_added, _}, 100
      end
    end

    test "message reply chain is preserved", %{messaging: messaging} do
      # Initial message
      {msg1, ctx1} =
        ingest!(messaging, "reply_chain_room", "user_1", "First message", 400,
          username: "user1",
          display_name: "User One"
        )

      # Bot reply to first message
      reply1 = reply!(messaging, msg1, ctx1, "Bot reply to first")
      assert reply1.reply_to_id == msg1.id

      # Second user message
      {msg2, ctx2} =
        ingest!(messaging, "reply_chain_room", "user_2", "Second message", 401,
          username: "user2",
          display_name: "User Two"
        )

      # Bot reply to second message
      reply2 = reply!(messaging, msg2, ctx2, "Bot reply to second")
      assert reply2.reply_to_id == msg2.id

      # Verify the chain in storage
      {:ok, messages} = messaging.list_messages(ctx1.room.id)

      # Find messages by content
      first_msg = Enum.find(messages, &(hd(&1.content).text == "First message"))
      first_reply = Enum.find(messages, &(hd(&1.content).text == "Bot reply to first"))
      second_msg = Enum.find(messages, &(hd(&1.content).text == "Second message"))
      second_reply = Enum.find(messages, &(hd(&1.content).text == "Bot reply to second"))

      assert first_reply.reply_to_id == first_msg.id
      assert second_reply.reply_to_id == second_msg.id
    end

    test "room server message limit is enforced", %{messaging: messaging} do
      # Create a room with many messages to test bounded history
      {_msg1, ctx} =
        ingest!(messaging, "bounded_room", "user_bounded", "Initial", 500,
          username: "bounded_user",
          display_name: "Bounded User"
        )

      room_id = ctx.room.id
      pid = RoomServer.whereis(messaging, room_id)

      # Get the message limit from state
      state = RoomServer.get_state(pid)
      message_limit = state.message_limit

      # Add more messages than the limit
      for i <- 501..(500 + message_limit + 10) do
        {msg, msg_ctx} = ingest!(messaging, "bounded_room", "user_bounded", "LegacyMessage #{i}", i)
        _reply = reply!(messaging, msg, msg_ctx, "Reply #{i}")
      end

      # RoomServer should only keep the most recent `message_limit` messages
      room_messages = RoomServer.get_messages(pid)
      assert length(room_messages) <= message_limit
    end
  end
end
