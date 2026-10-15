defmodule Jido.Messaging.MessageFactSizeTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Chat.Signal.{Identity, MessageReceived, Policy}
  alias Jido.Messaging.Runtime

  defmodule ControlledPersistence do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- Jido.Messaging.Persistence.ETS.__info__(:functions), name != :save_message do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: Jido.Messaging.Persistence.ETS
    end

    def save_message(state, message) do
      if Process.get({__MODULE__, :fail}),
        do: {:error, :store_unavailable},
        else: Jido.Messaging.Persistence.ETS.save_message(state, message)
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.MessageFactSizeTest.ControlledPersistence, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "size-binding", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    %{binding: binding, transport: transport}
  end

  defp exact_parent(binding) do
    parent =
      MessageReceived.new!(
        %{
          "item_id" => "item",
          "delivery_id" => "delivery",
          "room_id" => "provider-room",
          "message_id" => "provider-message",
          "sender" => %{"id" => "peer"},
          "text" => ""
        },
        source: binding.source,
        subject: Identity.conversation_subject(binding.id, "provider-room")
      )

    {:ok, json} = Jido.Signal.Serialization.serialize(parent)
    text = String.duplicate("x", 262_144 - byte_size(json))
    parent = %{parent | data: Map.put(parent.data, "text", text)}
    assert {:ok, ^parent} = Policy.validate(parent)
    assert {:ok, encoded} = Jido.Signal.Serialization.serialize(parent)
    assert byte_size(encoded) == 262_144
    {parent, text}
  end

  test "a maximum-size parent produces bounded runtime facts with the complete payload retained", context do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.room.message_added")
    {parent, text} = exact_parent(context.binding)
    {:ok, delivery} = Delivery.new(context.binding, "delivery", [parent])

    assert {:ok, [received]} = Instance.accept_delivery(delivery)
    assert received.type == "jido.messaging.message.received"
    assert %{"kind" => "result", "scope" => "call"} = received.data["resource_ref"]
    assert {:ok, snapshot} = Instance.resolve_resource(received.data["resource_ref"])
    assert snapshot["text"] == text
    assert snapshot["message_id"] == received.data["message_id"]
    assert {:ok, stored} = Instance.get_message(received.data["message_id"])
    assert [%Jido.Chat.Content.Text{text: ^text}] = stored.content
    assert_receive {:signal, added}
    assert added.type == "jido.messaging.room.message_added"
    assert added.data["message_id"] == received.data["message_id"]

    for child <- [received, added] do
      assert child.data["resource_ref"]
      refute Map.has_key?(child.data, "text")
      assert Jido.Signal.Context.get(child, "causationid") == parent.id
      assert Jido.Signal.Trace.get(child).trace_id == Jido.Signal.Trace.get(parent).trace_id
      assert {:ok, json} = Jido.Signal.Serialization.serialize(child)
      assert byte_size(json) <= 262_144
      {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
      assert {:ok, ^child} = Jido.Signal.Catalog.decode(catalog, json)
    end

    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert MockTransport.calls(context.transport) == []
    assert {:ok, [_one]} = Instance.list_messages(stored.room_id)
    refute_receive {:signal, _}
  end

  test "one byte beyond the parent limit rejects the whole unit before writes", context do
    {parent, text} = exact_parent(context.binding)
    oversized = %{parent | data: Map.put(parent.data, "text", text <> "x")}

    assert {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} =
             Instance.accept_delivery(%Delivery{id: "delivery", signals: [parent, oversized]})

    assert {:ok, []} = Instance.list_rooms()
    assert MockTransport.calls(context.transport) == []
  end

  test "a referenced message retains call ownership and cancellation", context do
    {parent, text} = exact_parent(context.binding)
    {:ok, delivery} = Delivery.new(context.binding, "delivery", [parent])
    assert {:ok, [received]} = Instance.accept_delivery(delivery)
    ref = received.data["resource_ref"]
    task = Task.async(fn -> Instance.resolve_resource(ref) end)
    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_owner_mismatch}} = Task.await(task)
    assert {:ok, %{"text" => ^text}} = Instance.resolve_resource(ref)
    assert :ok = Instance.cancel_resource(ref)

    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_cancelled}} =
             Instance.resolve_resource(ref)

    assert [{{:resource, _}, _, "result", nil, _, :cancelled}] =
             :ets.lookup(
               Runtime.resource_owner(Instance.__jido_messaging__(:runtime)).resources,
               {:resource, ref["id"]}
             )

    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert MockTransport.calls(context.transport) == []
  end

  test "a maximum-size local post retains its complete content and bounded result" do
    {room, request, actor} = local_post()
    {:ok, _} = Instance.subscribe_signals("jido.messaging.room.message_added")

    assert {:ok, result} = Instance.execute(request, actor)
    assert result.type == "jido.messaging.operation.completed"
    assert {:ok, summary} = Instance.resolve_resource(result.data["result"]["resource_ref"])
    assert summary["text"] == request.data["text"]
    assert {:ok, [stored]} = Instance.list_messages(room.id)
    assert stored.id == summary["id"]
    assert [%Jido.Chat.Content.Text{text: text}] = stored.content
    assert text == request.data["text"]
    assert_receive {:signal, fact}
    assert fact.type == "jido.messaging.room.message_added"
    assert {:ok, snapshot} = Instance.resolve_resource(fact.data["resource_ref"])
    assert snapshot["text"] == text

    for signal <- [fact, result] do
      assert {:ok, json} = Jido.Signal.Serialization.serialize(signal)
      assert byte_size(json) <= 262_144
      assert Jido.Signal.Context.get(signal, "causationid") == request.id
    end

    assert {:ok, ^result} = Instance.execute(request, actor)
    assert {:ok, [^stored]} = Instance.list_messages(room.id)
    refute_receive {:signal, _}
  end

  test "failed storage clears prepared large resources and cannot repeat acceptance" do
    {room, request, actor} = local_post()
    {:ok, _} = Instance.subscribe_signals("jido.messaging.room.message_added")
    Process.put({ControlledPersistence, :fail}, true)
    assert {:ok, failed} = Instance.execute(request, actor)
    assert failed.data["code"] == "persistence_failed"
    assert {:ok, []} = Instance.list_messages(room.id)
    owner = Runtime.resource_owner(Instance.__jido_messaging__(:runtime))
    resources = Enum.filter(:ets.tab2list(owner.resources), &match?({{:resource, _}, _, _, _, _, _}, &1))
    assert length(resources) == 2
    assert Enum.all?(resources, &match?({{:resource, _}, _, "result", nil, _, :cancelled}, &1))
    Process.delete({ControlledPersistence, :fail})
    assert {:ok, ^failed} = Instance.execute(request, actor)
    assert {:ok, []} = Instance.list_messages(room.id)

    assert Enum.filter(:ets.tab2list(owner.resources), &match?({{:resource, _}, _, _, _, _, _}, &1)) |> Enum.sort() ==
             Enum.sort(resources)

    refute_receive {:signal, _}
  end

  test "private resource resolution rejects unknown owners with a contract error" do
    ref = %{"id" => "absent", "scope" => "call", "binding_id" => "different-runtime", "kind" => "result"}
    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_resource}} = Instance.resolve_resource(ref)
    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_resource}} = Instance.cancel_resource(%{})
  end

  defp local_post do
    {:ok, room} = Instance.create_room(%{type: :group})
    {:ok, participant} = Instance.create_participant(%{type: :human})

    {:ok, _} =
      Instance.create_membership(%{principal_id: participant.id, room_id: room.id, issuer_principal_id: "host"})

    scope = Jido.Messaging.AuthorizationScope.new(%{kind: :room, room_id: room.id})

    {:ok, _} =
      Instance.create_principal_grant(%{
        principal_id: participant.id,
        issuer_principal_id: "host",
        actions: [:post_message],
        scope: scope
      })

    request =
      Jido.Messaging.Signal.PostMessage.new!(%{
        "request_id" => "large-post",
        "room_id" => room.id,
        "sender_id" => participant.id,
        "text" => ""
      })

    {:ok, json} = Jido.Signal.Serialization.serialize(request)
    request = %{request | data: Map.put(request.data, "text", String.duplicate("x", 262_144 - byte_size(json)))}
    assert {:ok, ^request} = Policy.validate(request)
    actor = [principal_id: participant.id, authorization_scope: scope]
    {room, request, actor}
  end
end
