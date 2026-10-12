defmodule Jido.Messaging.TypedAcceptanceTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.{Delivery, Signal.MessageReceived}
  alias Jido.Chat.Signal.Identity, as: ChatIdentity
  alias Jido.Messaging.{Events, Runtime}
  alias Jido.Messaging.Signal.Identity

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(Jido.Chat.AdapterTestKit.MockTransport)
    {:ok, binding} = Jido.Chat.bind(Jido.Chat.AdapterTestKit.MockAdapter, id: "typed-binding", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, binding: binding, transport: transport}
  end

  defp fact(binding, item \\ "one", extra \\ %{}) do
    MessageReceived.new!(
      Map.merge(
        %{
          "delivery_id" => "delivery",
          "item_id" => item,
          "room_id" => "room/1",
          "message_id" => item,
          "sender" => %{"id" => "peer"},
          "text" => item,
          "conversation_kind" => "group",
          "conversation_name" => "Group"
        },
        extra
      ),
      source: binding.source,
      subject: ChatIdentity.conversation_subject(binding.id, "room/1")
    )
  end

  defp participant_count do
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    :ets.info(state.participants, :size)
  end

  test "direct acceptance keeps the parent and emits typed canonical facts", %{binding: binding} do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.received")
    parent = fact(binding)
    before = Jido.Signal.to_map(parent)
    {:ok, delivery} = Delivery.new(binding, "delivery", [parent])
    assert {:ok, [child]} = Instance.accept_delivery(delivery)
    assert parent |> Jido.Signal.to_map() == before
    assert child.type == "jido.messaging.message.received"
    assert child.source == Events.source(Instance)
    assert child.subject == Identity.room_subject(child.data["room_id"])
    assert Jido.Signal.Context.get(child, "causationid") == parent.id
    assert Jido.Signal.Trace.get(child).trace_id == Jido.Signal.Trace.get(parent).trace_id
    assert {:ok, stored} = Instance.get_message(child.data["message_id"])
    assert stored.content |> hd() |> Map.fetch!(:text) == "one"
    assert {:ok, room} = Instance.get_room(stored.room_id)
    assert room.type == :group
    assert room.name == "Group"
    assert_receive {:signal, ^child}
    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert {:ok, [_one]} = Instance.list_messages(room.id)
    refute_receive {:signal, %{type: "jido.messaging.message.received"}}
  end

  test "the whole delivery is checked before any store write", %{binding: binding} do
    good = fact(binding)
    bad = %{fact(binding, "two") | dataschema: "urn:unknown:1"}
    assert {:error, _} = Instance.accept_delivery(%Delivery{id: "delivery", signals: [good, bad]})
    assert Instance.list_rooms() == {:ok, []}
    assert participant_count() == 0
  end

  test "ordered facts and an empty unit remain direct and typed", %{binding: binding} do
    assert {:ok, []} = Instance.accept_delivery(%Delivery{id: "empty", signals: []})
    {:ok, delivery} = Delivery.new(binding, "delivery", [fact(binding, "one"), fact(binding, "two")])
    assert {:ok, children} = Instance.accept_delivery(delivery)
    assert Enum.map(children, & &1.data["text"]) == ["one", "two"]
  end

  test "failed Bus observation does not release an accepted message", %{binding: binding} do
    supervisor = Instance.__jido_messaging__(:supervisor)
    {:ok, bus} = Jido.Signal.Bus.whereis(Module.concat(Instance, SignalBus))

    {id, ^bus, _type, _modules} =
      Enum.find(Supervisor.which_children(supervisor), fn {_id, pid, _type, _modules} -> pid == bus end)

    assert :ok = Supervisor.terminate_child(supervisor, id)
    parent = fact(binding)
    {:ok, delivery} = Delivery.new(binding, "delivery", [parent])
    assert {:ok, [child]} = Instance.accept_delivery(delivery)
    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert {:ok, [_stored]} = Instance.list_messages(child.data["room_id"])
  end

  test "published requests have no execution listener", %{binding: binding, transport: transport} do
    request =
      Jido.Messaging.Signal.SendMessage.new!(%{
        "request_id" => "bus-request",
        "room_id" => "room/1",
        "bridge_id" => binding.id,
        "text" => "hello"
      })

    assert {:ok, [_]} = Jido.Signal.Bus.publish(Module.concat(Instance, SignalBus), [request])
    assert Instance.list_rooms() == {:ok, []}
    assert participant_count() == 0
    assert {:error, _} = Jido.Messaging.Dispatch.emit(Instance, request)
    assert Jido.Chat.AdapterTestKit.MockTransport.calls(transport) == []
  end

  test "membership observation does not create records or runtime membership", %{binding: binding} do
    parent =
      Jido.Chat.Signal.MembershipChanged.new!(
        %{
          "delivery_id" => "delivery",
          "item_id" => "member",
          "room_id" => "room/1",
          "participant_id" => "external-member",
          "bot_self" => false,
          "transition" => "joined",
          "evidence" => "explicit_join",
          "previous" => nil,
          "current" => %{"status" => "member", "is_member" => true}
        },
        source: binding.source,
        subject: ChatIdentity.conversation_subject(binding.id, "room/1")
      )

    {:ok, delivery} = Delivery.new(binding, "delivery", [parent])
    assert {:ok, [observed]} = Instance.accept_delivery(delivery)
    assert observed.type == "jido.messaging.membership.observed"
    assert observed.subject == nil
    assert observed.data["room_id"] == nil
    assert observed.data["previous"] == nil
    assert Instance.list_rooms() == {:ok, []}
    assert participant_count() == 0
  end
end
