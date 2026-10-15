defmodule Jido.Messaging.EventsTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{AuthorizationScope, Events, TestMessaging}
  alias Jido.Messaging.Signal.{Identity, PostMessage}

  setup do
    start_supervised!(TestMessaging)
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Signals"})
    {:ok, participant} = TestMessaging.create_participant(%{type: :human})

    {:ok, _} =
      TestMessaging.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    scope = AuthorizationScope.new(%{kind: :room, room_id: room.id})

    {:ok, _} =
      TestMessaging.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message, :receive_message, :add_reaction, :remove_reaction],
        scope: scope
      })

    {:ok, room: room, participant: participant, actor: [principal_id: participant.id, authorization_scope: scope]}
  end

  defp post(context, text) do
    request =
      PostMessage.new!(%{
        "request_id" => Jido.Chat.ID.generate!(),
        "room_id" => context.room.id,
        "sender_id" => context.participant.id,
        "text" => text
      })

    {:ok, result} = TestMessaging.execute(request, context.actor)
    {:ok, message} = TestMessaging.get_message(result.data["result"]["id"])
    {request, message}
  end

  test "post_message persists and dispatches a message_added signal", context do
    {:ok, subscription} = TestMessaging.subscribe_signals("jido.messaging.room.message_added")
    {request, message} = post(context, "Hello from signals")
    assert message.content == [Jido.Chat.Content.Text.new("Hello from signals")]
    assert_receive {:signal, fact}
    assert fact.type == "jido.messaging.room.message_added"
    assert fact.subject == Identity.room_subject(context.room.id)
    assert fact.data["message_id"] == message.id
    assert fact.data["text"] == "Hello from signals"
    assert Jido.Signal.Context.get(fact, "causationid") == request.id
    :ok = TestMessaging.unsubscribe_signals(subscription)
  end

  test "save_message remains a persistence primitive without signal side effects", context do
    {:ok, subscription} = TestMessaging.subscribe_signals("jido.messaging.room.message_added")

    assert {:ok, _} =
             TestMessaging.save_message(%{
               room_id: context.room.id,
               sender_id: context.participant.id,
               role: :user,
               content: [Jido.Chat.Content.Text.new("No event")],
               status: :sent
             })

    refute_receive {:signal, _}
    :ok = TestMessaging.unsubscribe_signals(subscription)
  end

  test "event metadata is CloudEvents-friendly plain data", context do
    {:ok, _} = TestMessaging.subscribe_signals("jido.messaging.room.message_added")
    {_request, _message} = post(context, "Plain metadata")
    assert_receive {:signal, fact}
    assert fact.source == Events.source(TestMessaging)
    assert fact.subject == Identity.room_subject(context.room.id)
    assert {:ok, encoded} = Jido.Signal.Serialization.serialize(fact)
    assert {:ok, ^fact} = Jido.Signal.Serialization.deserialize(encoded)
    assert Enum.all?(Map.keys(fact.data), &is_binary/1)
    refute Map.has_key?(fact.data, "context")
    refute Map.has_key?(fact.data, "raw")
  end

  test "event constructors normalize string option keys without creating atoms", context do
    {_request, message} = post(context, "String options")
    unknown = "untrusted_option_#{System.unique_integer([:positive])}"
    opts = %{"instance_id" => "demo", "bridge_id" => "bridge", "external_room_id" => "general", unknown => "ignored"}
    assert {:ok, fact} = Events.message_added(TestMessaging, message, opts)
    assert fact.source == Identity.instance_source("demo")
    assert fact.data["external_room_id"] == "general"
    assert fact.data["bridge_id"] == "bridge"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert Events.telemetry_event_for("jido.messaging.participant.presence_changed") == [
             :jido_messaging,
             :participant,
             :presence_changed
           ]

    assert Events.telemetry_event_for("third.party.untrusted_event") == [:jido_messaging, :signal, :custom]
  end

  test "reaction commands persist and dispatch reaction signals", context do
    {_request, message} = post(context, "React here")
    {:ok, subscription} = TestMessaging.subscribe_signals("jido.messaging.message.**")

    data = %{
      "room_id" => context.room.id,
      "message_id" => message.id,
      "participant_id" => context.participant.id,
      "reaction" => "+1"
    }

    for {definition, id, expected_type} <- [
          {Jido.Messaging.Signal.AddRoomReaction, "add", "jido.messaging.message.reaction_added"},
          {Jido.Messaging.Signal.RemoveRoomReaction, "remove", "jido.messaging.message.reaction_removed"}
        ] do
      request = definition.new!(Map.put(data, "request_id", id))
      assert {:ok, _} = TestMessaging.execute(request, context.actor)
      assert_receive {:signal, fact}
      assert fact.type == expected_type
      assert fact.data["participant_id"] == context.participant.id
      assert fact.data["reaction"] == "+1"
      assert {:ok, changed} = TestMessaging.get_message(message.id)

      if id == "add",
        do: assert(changed.reactions["+1"] == [context.participant.id]),
        else: assert(changed.reactions == %{})

      assert {:ok, _} =
               TestMessaging.execute(definition.new!(Map.put(data, "request_id", id <> "-again")), context.actor)

      refute_receive {:signal, _}
    end

    :ok = TestMessaging.unsubscribe_signals(subscription)
  end

  test "participant activity helpers dispatch canonical signals", context do
    {:ok, subscription} = TestMessaging.subscribe_signals("jido.messaging.**")
    data = %{"room_id" => context.room.id, "participant_id" => context.participant.id}

    for {definition, extra, type} <- [
          {Jido.Messaging.Signal.ParticipantJoinedRequest, %{}, "jido.messaging.room.participant_joined"},
          {Jido.Messaging.Signal.SetPresence, %{"presence" => "online"}, "jido.messaging.participant.presence_changed"},
          {Jido.Messaging.Signal.SetTyping, %{"typing" => true}, "jido.messaging.participant.typing"},
          {Jido.Messaging.Signal.ParticipantLeftRequest, %{}, "jido.messaging.room.participant_left"}
        ] do
      request = definition.new!(data |> Map.merge(extra) |> Map.put("request_id", type))
      assert {:ok, _} = TestMessaging.execute(request, context.actor)
      assert_receive {:signal, fact}
      assert fact.type == type
      assert fact.subject == Identity.room_subject(context.room.id)
      assert fact.data["participant_id"] == context.participant.id
      assert Jido.Signal.Context.get(fact, "causationid") == request.id
      assert_receive {:signal, %{type: "jido.messaging.operation.completed"}}
    end

    :ok = TestMessaging.unsubscribe_signals(subscription)
  end
end
