defmodule Jido.Messaging.IntegrationTest do
  @moduledoc """
  Integration tests verifying the full ingest → deliver flow.
  """
  use ExUnit.Case, async: true

  alias Jido.Chat.Content.Text
  alias Jido.Messaging.{Ingest, Deliver, RoomServer, RoomSupervisor}

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule MockTelegramChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, %{message: msg}) do
      id = to_string(msg.message_id)

      fact =
        Jido.Chat.AdapterTestKit.Factories.message_received(binding, %{
          "delivery_id" => id,
          "item_id" => id,
          "message_id" => id,
          "room_id" => to_string(msg.chat_id),
          "sender" => %{"id" => to_string(msg.user_id), "username" => msg.username, "display_name" => msg.display_name},
          "text" => msg.text,
          "conversation_kind" => "direct"
        })

      Jido.Chat.Delivery.new(binding, id, [fact])
    end

    @impl true
    def send_message(chat_id, text, _opts) do
      {:ok, %{message_id: System.unique_integer([:positive]), chat_id: chat_id, text: text}}
    end
  end

  setup do
    start_supervised!(TestMessaging)
    TestMessaging.clear_dedupe()
    :ok
  end

  defp accept_raw(bridge, raw) do
    {:ok, binding} = Jido.Chat.bind(MockTelegramChannel, id: bridge)
    :ok = Jido.Messaging.Runtime.register_binding(TestMessaging.__jido_messaging__(:runtime), binding)
    {:ok, delivery} = Jido.Chat.normalize_event(binding, raw)
    {:ok, [fact]} = TestMessaging.accept_delivery(delivery)
    {:ok, message} = TestMessaging.get_message(fact.data["message_id"])
    server = RoomServer.whereis(TestMessaging, message.room_id)
    {:ok, message, RoomServer.message_context(server, message.id)}
  end

  describe "full message flow" do
    test "ingest incoming message and deliver reply" do
      raw_update = %{
        message: %{
          message_id: 1001,
          date: System.system_time(:second),
          chat_id: 12345,
          user_id: 67890,
          username: "alice",
          display_name: "Alice",
          text: "Hello bot!"
        }
      }

      {:ok, message, context} = accept_raw("bot_1", raw_update)

      assert message.role == :user
      assert [%Text{text: "Hello bot!"}] = message.content
      assert context.room.type == :direct
      assert context.participant.type == :human

      {:ok, reply} = Deliver.deliver_outgoing(TestMessaging, message, "Hi Alice!", context)

      assert reply.role == :assistant
      assert reply.reply_to_id == message.id
      assert reply.status == :sent
      assert [%Text{text: "Hi Alice!"}] = reply.content

      {:ok, messages} = TestMessaging.list_messages(message.room_id)
      assert length(messages) == 2

      [first, second] = messages
      assert first.role == :user
      assert second.role == :assistant
    end

    test "multiple messages in same room share room_id" do
      for i <- 1..3 do
        incoming = %{
          external_room_id: "persistent_chat",
          external_user_id: "user_#{i}",
          text: "Message #{i}",
          external_message_id: 10_000 + i
        }

        {:ok, _msg, ctx} = Ingest.ingest_incoming(TestMessaging, MockTelegramChannel, "bot", incoming)
        assert ctx.room.id != nil
      end

      {:ok, rooms} = TestMessaging.list_rooms()

      room_ids_for_chat =
        Enum.filter(rooms, fn r ->
          r.external_bindings[:telegram]["bot"] == "persistent_chat"
        end)

      assert length(room_ids_for_chat) == 1
    end

    test "echo bot pattern" do
      echo_handler = fn message, _context ->
        text = hd(message.content).text
        {:reply, "Echo: #{text}"}
      end

      incoming = %{
        external_room_id: "echo_chat",
        external_user_id: "echo_user",
        text: "Test echo",
        external_message_id: 20_001
      }

      {:ok, message, context} = Ingest.ingest_incoming(TestMessaging, MockTelegramChannel, "echo_bot", incoming)

      case echo_handler.(message, context) do
        {:reply, reply_text} ->
          {:ok, reply} = Deliver.deliver_outgoing(TestMessaging, message, reply_text, context)
          assert [%Text{text: "Echo: Test echo"}] = reply.content
      end
    end
  end

  describe "RoomServer integration" do
    test "messages appear in RoomServer state after ingest and deliver" do
      raw_update = %{
        message: %{
          message_id: 2001,
          date: System.system_time(:second),
          chat_id: 99999,
          user_id: 88888,
          username: "bob",
          display_name: "Bob",
          text: "Hello from Bob!"
        }
      }

      {:ok, message, context} = accept_raw("bot_2", raw_update)

      room_id = context.room.id
      pid = RoomServer.whereis(TestMessaging, room_id)
      assert pid != nil

      room_messages = RoomServer.get_messages(pid)
      assert length(room_messages) == 1
      assert hd(room_messages).id == message.id

      {:ok, reply} = Deliver.deliver_outgoing(TestMessaging, message, "Hi Bob!", context)

      room_messages = RoomServer.get_messages(pid)
      assert length(room_messages) == 2

      [latest, first] = room_messages
      assert latest.id == reply.id
      assert first.id == message.id
    end

    test "RoomServer.get_messages returns conversation history" do
      incoming1 = %{
        external_room_id: "history_chat",
        external_user_id: "history_user",
        text: "First message",
        external_message_id: 30_001
      }

      {:ok, msg1, ctx} = Ingest.ingest_incoming(TestMessaging, MockTelegramChannel, "history_bot", incoming1)

      {:ok, reply1} = Deliver.deliver_outgoing(TestMessaging, msg1, "Reply 1", ctx)

      incoming2 = %{
        external_room_id: "history_chat",
        external_user_id: "history_user",
        text: "Second message",
        external_message_id: 30_002
      }

      {:ok, msg2, _ctx} = Ingest.ingest_incoming(TestMessaging, MockTelegramChannel, "history_bot", incoming2)

      pid = RoomServer.whereis(TestMessaging, ctx.room.id)
      messages = RoomServer.get_messages(pid)

      assert length(messages) == 3
      assert Enum.map(messages, & &1.id) == [msg2.id, reply1.id, msg1.id]
    end

    test "RoomServer tracks participants" do
      incoming = %{
        external_room_id: "participant_chat",
        external_user_id: "participant_user",
        text: "Test participant tracking",
        username: "testuser",
        display_name: "Test User",
        external_message_id: 40_001
      }

      {:ok, _message, context} = Ingest.ingest_incoming(TestMessaging, MockTelegramChannel, "part_bot", incoming)

      pid = RoomServer.whereis(TestMessaging, context.room.id)
      participants = RoomServer.get_participants(pid)

      assert length(participants) == 1
      assert hd(participants).id == context.participant.id
    end

    test "RoomSupervisor counts running rooms" do
      initial_count = RoomSupervisor.count_rooms(TestMessaging)

      incoming = %{
        external_room_id: "count_chat_#{System.unique_integer()}",
        external_user_id: "count_user",
        text: "Test room count",
        external_message_id: 50_001
      }

      {:ok, _message, _context} = Ingest.ingest_incoming(TestMessaging, MockTelegramChannel, "count_bot", incoming)

      assert RoomSupervisor.count_rooms(TestMessaging) == initial_count + 1
    end
  end
end
