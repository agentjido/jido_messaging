defmodule Jido.Messaging.NativeMediaDeliveryRetryTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.Factories, AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.{Deduper, Runtime}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "media-retry", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, _} = Instance.subscribe_signals("jido.chat.message.received")
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.received")
    %{binding: binding, transport: transport}
  end

  for failure <- [:cancelled, :failed, :expired, :invalid_value, :wrong_kind] do
    test "#{failure} later resource retains the first acceptance and permits ordered retry", context do
      binding = context.binding
      {:ok, first_ref} = resource(binding, "first bytes")
      {:ok, last_ref} = resource(binding, "last bytes")
      first = fact(binding, "first", first_ref)
      middle = fact(binding, "middle", unavailable_ref(binding, unquote(failure)))
      last = fact(binding, "last", last_ref)
      parents = [first, middle, last]
      originals = Enum.map(parents, &Jido.Signal.to_map/1)
      {:ok, delivery} = Delivery.new(binding, "unit", parents)

      assert {:error, %Contract{}} = Instance.accept_delivery(delivery)
      assert_receive {:signal, ^first}
      assert_receive {:signal, first_child}
      assert_child(first_child, first)
      assert {:ok, stored_first} = Instance.get_message(first_child.data["message_id"])
      assert {:ok, [^stored_first]} = Instance.list_messages(stored_first.room_id)
      assert_missing(binding, "middle")
      assert_missing(binding, "last")
      assert Deduper.count(Instance) == 2
      refute_received {:signal, _}

      # An accepted item must dedupe before it tries to resolve its old resource.
      assert :ok = Jido.Chat.cancel_resource(binding, first_ref)
      assert {:error, %Contract{}} = Instance.accept_delivery(delivery)
      assert {:ok, [^stored_first]} = Instance.list_messages(stored_first.room_id)
      refute_received {:signal, _}

      {:ok, replacement_ref} = resource(binding, "middle bytes")
      replacement = put_in(middle.data["media"], [%{"kind" => "image", "resource_ref" => replacement_ref}])
      {:ok, retry} = Delivery.new(binding, "unit", [first, replacement, last])
      assert {:ok, [middle_child, last_child]} = Instance.accept_delivery(retry)
      assert_child(middle_child, replacement)
      assert_child(last_child, last)
      assert_receive {:signal, ^replacement}
      assert_receive {:signal, ^middle_child}
      assert_receive {:signal, ^last}
      assert_receive {:signal, ^last_child}
      refute_received {:signal, _}

      assert {:ok, messages} = Instance.list_messages(stored_first.room_id)
      assert Enum.sort(Enum.map(messages, & &1.external_id)) == ["first", "last", "middle"]

      for {child, bytes} <- [{first_child, "first bytes"}, {middle_child, "middle bytes"}, {last_child, "last bytes"}] do
        assert {:ok, stored} = Instance.get_message(child.data["message_id"])
        assert [%Jido.Chat.Content.Text{}, %Jido.Chat.Content.Image{data: ^bytes}] = stored.content
      end

      assert Deduper.count(Instance) == 6
      assert {:ok, []} = Instance.accept_delivery(retry)
      assert {:ok, ^messages} = Instance.list_messages(stored_first.room_id)
      assert Enum.map(parents, &Jido.Signal.to_map/1) == originals
      assert MockTransport.calls(context.transport) == []
      refute_receive {:signal, _}
    end
  end

  defp fact(binding, item, ref) do
    Factories.message_received(binding, %{
      "delivery_id" => "unit",
      "item_id" => item,
      "message_id" => item,
      "text" => item,
      "media" => [%{"kind" => "image", "resource_ref" => ref}]
    })
  end

  defp resource(binding, bytes), do: Jido.Chat.put_resource(binding, "media", %{data: bytes, media_type: "image/png"})

  defp assert_child(child, parent) do
    assert child.type == "jido.messaging.message.received"
    assert child.data["text"] == parent.data["text"]
    assert Jido.Signal.Context.get(child, "causationid") == parent.id
    assert Jido.Signal.Trace.get(child).trace_id == Jido.Signal.Trace.get(parent).trace_id
  end

  defp assert_missing(binding, external_id) do
    assert {:error, :not_found} = Instance.get_message_by_external_id(:test, binding.id, external_id)
  end

  defp unavailable_ref(binding, :expired) do
    {:ok, ref} = Jido.Chat.Resources.put(binding, "media", %{data: "middle bytes"}, ttl_ms: 0)
    ref
  end

  defp unavailable_ref(binding, :invalid_value) do
    {:ok, ref} = Jido.Chat.put_resource(binding, "media", :invalid)
    ref
  end

  defp unavailable_ref(binding, :wrong_kind) do
    {:ok, ref} = Jido.Chat.put_resource(binding, "result", %{data: "middle bytes"})
    ref
  end

  defp unavailable_ref(binding, state) do
    {:ok, ref} = resource(binding, "middle bytes")
    if state == :cancelled, do: Jido.Chat.cancel_resource(binding, ref), else: Jido.Chat.Resources.fail(binding, ref)
    ref
  end
end
