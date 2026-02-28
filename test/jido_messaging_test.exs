defmodule Jido.MessagingTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.TestMessaging

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "use Jido.Messaging" do
    test "generates child_spec/1" do
      spec = TestMessaging.child_spec([])
      assert spec.id == TestMessaging
      assert spec.type == :supervisor
    end

    test "__jido_messaging__/1 returns correct names" do
      assert TestMessaging.__jido_messaging__(:supervisor) == Jido.Messaging.TestMessaging.Supervisor
      assert TestMessaging.__jido_messaging__(:runtime) == Jido.Messaging.TestMessaging.Runtime
      assert TestMessaging.__jido_messaging__(:persistence) == Jido.Messaging.Persistence.ETS
    end

    test "supports core runtime profile without onboarding supervisors" do
      start_supervised!(Jido.Messaging.CoreProfileMessaging)

      assert Process.whereis(Jido.Messaging.CoreProfileMessaging.__jido_messaging__(:onboarding_supervisor)) == nil
      assert Process.whereis(Jido.Messaging.CoreProfileMessaging.__jido_messaging__(:onboarding_registry)) == nil
    end
  end

  describe "room API" do
    test "create_room/1 creates a room" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct, name: "Test"})

      assert room.type == :direct
      assert room.name == "Test"
      assert is_binary(room.id)
      assert String.starts_with?(room.id, "jch_")
    end

    test "get_room/1 fetches room" do
      {:ok, room} = TestMessaging.create_room(%{type: :group})
      {:ok, fetched} = TestMessaging.get_room(room.id)

      assert fetched.id == room.id
    end

    test "list_rooms/0 returns rooms" do
      {:ok, _} = TestMessaging.create_room(%{type: :direct})
      {:ok, _} = TestMessaging.create_room(%{type: :group})

      {:ok, rooms} = TestMessaging.list_rooms()
      assert length(rooms) == 2
    end

    test "delete_room/1 removes room" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})
      :ok = TestMessaging.delete_room(room.id)

      assert {:error, :not_found} = TestMessaging.get_room(room.id)
    end
  end

  describe "participant API" do
    test "create_participant/1 creates participant" do
      {:ok, participant} =
        TestMessaging.create_participant(%{
          type: :human,
          identity: %{name: "Alice"}
        })

      assert participant.type == :human
      assert participant.identity.name == "Alice"
    end

    test "get_participant/1 fetches participant" do
      {:ok, participant} = TestMessaging.create_participant(%{type: :agent})
      {:ok, fetched} = TestMessaging.get_participant(participant.id)

      assert fetched.id == participant.id
    end
  end

  describe "message API" do
    test "save_message/1 creates message" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})
      {:ok, participant} = TestMessaging.create_participant(%{type: :human})

      {:ok, message} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: participant.id,
          role: :user,
          content: [%{type: :text, text: "Hello!"}]
        })

      assert message.role == :user
      assert message.content == [%{type: :text, text: "Hello!"}]
    end

    test "list_messages/1 returns messages for room" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, _} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "u1",
          role: :user,
          content: []
        })

      {:ok, _} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "u2",
          role: :assistant,
          content: []
        })

      {:ok, messages} = TestMessaging.list_messages(room.id)
      assert length(messages) == 2
    end

    test "get_message/1 fetches message" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, message} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "u1",
          role: :user,
          content: []
        })

      {:ok, fetched} = TestMessaging.get_message(message.id)
      assert fetched.id == message.id
    end

    test "delete_message/1 removes message" do
      {:ok, room} = TestMessaging.create_room(%{type: :direct})

      {:ok, message} =
        TestMessaging.save_message(%{
          room_id: room.id,
          sender_id: "u1",
          role: :user,
          content: []
        })

      :ok = TestMessaging.delete_message(message.id)
      assert {:error, :not_found} = TestMessaging.get_message(message.id)
    end
  end

  describe "external binding API" do
    test "get_or_create_room_by_external_binding/4" do
      {:ok, room} =
        TestMessaging.get_or_create_room_by_external_binding(
          :telegram,
          "bot_1",
          "chat_123",
          %{type: :direct}
        )

      assert room.type == :direct

      {:ok, same_room} =
        TestMessaging.get_or_create_room_by_external_binding(
          :telegram,
          "bot_1",
          "chat_123"
        )

      assert same_room.id == room.id
    end

    test "get_or_create_participant_by_external_id/3" do
      {:ok, participant} =
        TestMessaging.get_or_create_participant_by_external_id(
          :telegram,
          "user_456",
          %{type: :human}
        )

      assert participant.type == :human

      {:ok, same} =
        TestMessaging.get_or_create_participant_by_external_id(
          :telegram,
          "user_456"
        )

      assert same.id == participant.id
    end
  end
end
