defmodule Jido.Messaging.IngressSinkTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.AdapterTestKit.{Factories, MockAdapter}
  alias Jido.Messaging.{IngressSink, Runtime}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, a} = Jido.Chat.bind(MockAdapter, id: "bridge_sink")
    {:ok, b} = Jido.Chat.bind(MockAdapter, id: "bridge_sink_b")
    runtime = Instance.__jido_messaging__(:runtime)
    :ok = Runtime.register_binding(runtime, a)
    :ok = Runtime.register_binding(runtime, b)
    {:ok, a: a, b: b}
  end

  defp delivery(binding) do
    fact =
      Factories.message_received(binding, %{
        "delivery_id" => "delivery",
        "item_id" => "shared",
        "message_id" => "shared",
        "room_id" => "shared-room",
        "sender" => %{"id" => "shared-user"},
        "text" => "hello"
      })

    {:ok, delivery} = Jido.Chat.Delivery.new(binding, "delivery", [fact])
    delivery
  end

  test "raw input and HTTP metadata cannot cause implicit parsing" do
    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_delivery}} =
             IngressSink.emit(Instance, "bridge_sink", %{"kind" => "noop"},
               headers: %{"authorization" => "private"},
               mode: :webhook
             )

    assert Instance.list_rooms() == {:ok, []}
  end

  test "a complete normalized delivery returns a typed canonical fact", context do
    assert {:ok, [fact]} = IngressSink.emit(Instance, context.a.id, delivery(context.a))
    assert fact.type == "jido.messaging.message.received"
    assert fact.data["bridge_id"] == context.a.id
    assert {:ok, stored} = Instance.get_message(fact.data["message_id"])
    assert stored.external_id == "shared"
  end

  test "dedupe and canonical identity stay isolated across bindings", context do
    a = delivery(context.a)
    b = delivery(context.b)
    assert {:ok, [first]} = IngressSink.emit(Instance, context.a.id, a)
    assert {:ok, [second]} = IngressSink.emit(Instance, context.b.id, b)
    assert first.data["bridge_id"] == context.a.id
    assert second.data["bridge_id"] == context.b.id
    assert first.data["room_id"] != second.data["room_id"]
    assert {:ok, []} = IngressSink.emit(Instance, context.a.id, a)
    assert {:error, _} = IngressSink.emit(Instance, context.b.id, a)
    assert {:ok, [_one]} = Instance.list_messages(first.data["room_id"])
    assert {:ok, [_one]} = Instance.list_messages(second.data["room_id"])
  end
end
