defmodule Jido.Messaging.EventProjectionBoundaryTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{Dispatch, Events, Runtime}
  alias Jido.Messaging.Signal.{Identity, PostMessage}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "owned-room", type: :group})
    {:ok, foreign_room} = Instance.create_room(%{id: "foreign-room", type: :group})
    {:ok, participant} = Instance.create_participant(%{id: "owner", type: :human})

    messages =
      for current <- [room, foreign_room] do
        {:ok, message} =
          Instance.save_message(%{
            id: "message-" <> current.id,
            room_id: current.id,
            sender_id: participant.id,
            role: :user,
            status: :sent,
            content: [%{type: :text, text: "Complete é " <> current.id}],
            metadata: %{private_token: "fixture-private", complete: current.id},
            external_id: "provider-message"
          })

        message
      end

    parent =
      PostMessage.new!(%{
        "request_id" => "parent",
        "room_id" => room.id,
        "sender_id" => participant.id,
        "text" => "Cause"
      })

    {:ok,
     runtime: Instance.__jido_messaging__(:runtime),
     room: room,
     participant: participant,
     messages: messages,
     owned: hd(messages),
     foreign: List.last(messages),
     parent: parent}
  end

  for event <- [:message_added, :message_received, :message_sent], form <- [:record, :summary] do
    test "#{event} #{form} cannot place a foreign message under the owned subject", context do
      data = if unquote(form) == :record, do: %{message: context.foreign}, else: Events.message_data(context.foreign)

      assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_context}} =
               Events.room_event(Instance, unquote(event), context.room.id, data, parent_signal: context.parent)

      assert_unchanged(context)
    end
  end

  for {event, helper} <- [
        {:message_added, :message_added},
        {:message_received, :message_received},
        {:message_sent, :message_sent}
      ] do
    test "#{event} retains full safe fields, native JSON and direct parent causation", context do
      before = Jido.Signal.to_map(context.parent)

      opts = %{
        "parent_signal" => context.parent,
        "instance_id" => "public-fixture",
        "external_room_id" => "provider-room",
        "bridge_id" => "provider-bridge"
      }

      assert {:ok, fact} = apply(Events, unquote(helper), [Instance, context.owned, opts])
      assert fact.type == Events.type_for(unquote(event))
      assert fact.source == Identity.instance_source("public-fixture")
      assert fact.subject == Identity.room_subject(context.room.id)
      assert fact.data["text"] == "Complete é owned-room"
      assert fact.data["message_id"] == context.owned.id
      assert fact.data["message"]["room_id"] == context.room.id
      assert fact.data["external_message_id"] == "provider-message"
      assert fact.data["bridge_id"] == "provider-bridge"
      assert fact.data["external_room_id"] == "provider-room"
      assert Jido.Signal.to_map(context.parent) == before
      assert_causal_json(fact, context)
      refute Jason.encode!(Jido.Signal.to_map(fact)) =~ "fixture-private"
      assert_unchanged(context)
    end
  end

  test "participant record projection preserves canonical room and host reason", context do
    for event <- [:participant_joined, :participant_left] do
      assert {:ok, fact} =
               Events.room_event(
                 Instance,
                 event,
                 context.room.id,
                 %{
                   "room_id" => "spoofed",
                   "participant" => %{"id" => context.participant.id},
                   "token" => "fixture-private"
                 },
                 reason: "host-observed",
                 parent_signal: context.parent
               )

      assert fact.data == %{
               "room_id" => context.room.id,
               "participant_id" => context.participant.id,
               "reason" => "host-observed"
             }

      assert_causal_json(fact, context)
    end

    assert_unchanged(context)
  end

  test "presence, false typing and thread aliases preserve complete scalar fields", context do
    for {event, data, expected} <- [
          {:presence_changed, %{participant_id: context.participant.id, to: :away},
           %{"room_id" => context.room.id, "participant_id" => context.participant.id, "presence" => "away"}},
          {:typing, %{"participant_id" => context.participant.id, "is_typing" => false},
           %{"room_id" => context.room.id, "participant_id" => context.participant.id, "typing" => false}},
          {:thread_created, %{root_message_id: "root-thread"},
           %{"room_id" => context.room.id, "thread_id" => "root-thread"}},
          {:thread_reply_added, %{"root_message_id" => "root-thread", "message_id" => context.owned.id},
           %{"room_id" => context.room.id, "thread_id" => "root-thread", "message_id" => context.owned.id}}
        ] do
      assert {:ok, fact} = Events.room_event(Instance, event, context.room.id, data, parent_signal: context.parent)
      assert fact.data == expected
      assert_causal_json(fact, context)
    end

    assert_unchanged(context)
  end

  test "failure projection exposes only the defined safe code", context do
    for {reason, code} <- [
          {:persistence_failed, "persistence_failed"},
          {:authorization_denied, "authorization_denied"},
          {:observation_failed, "observation_failed"},
          {:unsupported, "provider_failure"},
          {:timeout, "provider_failure"},
          {:provider_failure, "provider_failure"},
          {%{token: "fixture-private", pid: self()}, "delivery_failed"}
        ] do
      assert {:ok, fact} =
               Events.message_failed(Instance, context.room.id, reason,
                 parent_signal: context.parent,
                 message_id: context.owned.id,
                 bridge_id: "provider-bridge"
               )

      assert fact.data == %{
               "room_id" => context.room.id,
               "message_id" => context.owned.id,
               "bridge_id" => "provider-bridge",
               "code" => code
             }

      assert_causal_json(fact, context)
    end

    assert_unchanged(context)
  end

  test "native Bus selection uses projected subject and source without record writes", context do
    source = Events.source(Instance)
    subject = Identity.room_subject(context.room.id)
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.sent", selector: [source: source, subject: subject])

    {:ok, _} =
      Instance.subscribe_signals("jido.messaging.message.sent", selector: [source: "urn:wrong", subject: subject])

    {:ok, _} =
      Instance.subscribe_signals("jido.messaging.message.sent",
        selector: [source: source, subject: Identity.room_subject("foreign-room")]
      )

    assert {:ok, fact} = Events.message_sent(Instance, context.owned, parent_signal: context.parent)
    assert {:ok, ^fact} = Dispatch.emit(Instance, fact)
    assert_receive {:signal, ^fact}
    refute_receive {:signal, _}
    assert_unchanged(context)
  end

  test "unknown definition, schema override and invalid parent return no fact", context do
    assert {:error, %Jido.Chat.Errors.Contract{code: :unknown_definition}} =
             Events.new(:unregistered, Instance, context.room.id, %{})

    assert {:error, %Jido.Chat.Errors.Contract{code: :unknown_definition}} =
             Events.message_sent(Instance, context.owned, dataschema: "urn:override")

    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_context}} =
             Events.message_sent(Instance, context.owned, parent_signal: self())

    assert_unchanged(context)
  end

  defp assert_causal_json(fact, context) do
    assert Jido.Signal.Context.get(fact, "causationid") == context.parent.id
    assert Jido.Signal.Trace.get(fact).trace_id == Jido.Signal.Trace.get(context.parent).trace_id
    assert {:ok, json} = Jido.Signal.Serialization.serialize(fact)
    {:ok, catalog} = Runtime.catalog(context.runtime)
    assert {:ok, ^fact} = Jido.Signal.Catalog.decode(catalog, json)
    assert Enum.all?(Map.keys(fact.data), &is_binary/1)
  end

  defp assert_unchanged(context) do
    for original <- context.messages, do: assert({:ok, original} == Instance.get_message(original.id))
    assert {:ok, participant} = Instance.get_participant(context.participant.id)
    assert participant == context.participant
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert Instance.count_agents() == 0
    assert {:ok, []} = Instance.list_memberships(context.room.id)
    assert {:ok, []} = Instance.list_principal_grants(context.participant.id)
  end
end
