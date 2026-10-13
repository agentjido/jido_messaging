defmodule Jido.Messaging.AcceptanceFailureTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Chat.Errors.Contract
  alias Jido.Chat.Signal.{Identity, MembershipChanged, MessageReceived, MessageUpdated}
  alias Jido.Messaging.{Deduper, Runtime}

  defmodule ControlledPersistence do
    @behaviour Jido.Messaging.Persistence

    for {name, arity} <- Jido.Messaging.Persistence.ETS.__info__(:functions),
        name not in [:get_room_by_external_binding, :save_message] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: Jido.Messaging.Persistence.ETS
    end

    def get_room_by_external_binding(state, channel, bridge, external) do
      Process.put({__MODULE__, :lookups}, Process.get({__MODULE__, :lookups}, []) ++ [external])

      case Process.get({__MODULE__, :lookup_failure}) do
        {^external, :raise} -> raise "private-store-detail"
        {^external, :throw} -> throw({:private_store_detail, self()})
        {^external, :exit} -> exit({:private_store_detail, self()})
        {^external, :invalid} -> :private_store_detail
        {^external, :error} -> {:error, %{token: "private-store-detail", pid: self()}}
        _ -> Jido.Messaging.Persistence.ETS.get_room_by_external_binding(state, channel, bridge, external)
      end
    end

    def save_message(state, message) do
      Process.put({__MODULE__, :writes}, Process.get({__MODULE__, :writes}, 0) + 1)

      if Process.get({__MODULE__, :write_failure}),
        do: {:error, %{token: "private-store-detail", pid: self()}},
        else: Jido.Messaging.Persistence.ETS.save_message(state, message)
    end
  end

  defmodule Instance do
    use Jido.Messaging,
      persistence: Jido.Messaging.AcceptanceFailureTest.ControlledPersistence,
      runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "acceptance-failure", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    %{binding: binding, transport: transport}
  end

  defp membership(binding, item, room) do
    MembershipChanged.new!(
      %{
        "delivery_id" => "unit",
        "item_id" => item,
        "room_id" => room,
        "participant_id" => "peer",
        "bot_self" => false,
        "transition" => "joined",
        "evidence" => "explicit_join",
        "previous" => nil,
        "current" => %{"status" => "member", "is_member" => true}
      },
      source: binding.source,
      subject: Identity.conversation_subject(binding.id, room)
    )
  end

  defp delivery(binding, parents) do
    {:ok, unit} = Delivery.new(binding, "unit", parents)
    unit
  end

  defp snapshot do
    {_, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    Map.new(Map.from_struct(state), fn {name, table} -> {name, Enum.sort(:ets.tab2list(table))} end)
  end

  defp assert_safe_error(error) do
    assert {:error, %Contract{code: :handler_failed}} = error
    refute inspect(error) =~ "private-store-detail"
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "membership lookup #{mode} rejects the item and permits a safe retry", context do
      mode = unquote(mode)

      {:ok, room} =
        Instance.get_or_create_room_by_external_binding(:test, context.binding.id, "provider-room", %{type: :group})

      parent = membership(context.binding, "member", "provider-room")
      unit = delivery(context.binding, [parent])
      original = Jido.Signal.to_map(parent)
      before = snapshot()
      {:ok, _} = Instance.subscribe_signals("jido.messaging.membership.observed")
      Process.put({ControlledPersistence, :lookup_failure}, {"provider-room", mode})

      assert_safe_error(Instance.accept_delivery(unit))
      assert snapshot() == before
      assert Deduper.count(Instance) == 0
      assert MockTransport.calls(context.transport) == []
      refute_received {:signal, _}

      Process.delete({ControlledPersistence, :lookup_failure})
      assert {:ok, [observed]} = Instance.accept_delivery(unit)
      assert observed.data["room_id"] == room.id
      assert Jido.Signal.Context.get(observed, "causationid") == parent.id
      assert Jido.Signal.Trace.get(observed).trace_id == Jido.Signal.Trace.get(parent).trace_id
      assert Jido.Signal.to_map(parent) == original
      assert snapshot() == before
      assert_receive {:signal, ^observed}
      assert {:ok, []} = Instance.accept_delivery(unit)
      refute_received {:signal, _}
    end
  end

  test "a failed middle item keeps the first observation and retries the remaining ordered items", context do
    parents =
      for {item, room} <- [{"first", "good"}, {"second", "bad"}, {"third", "later"}],
          do: membership(context.binding, item, room)

    [first, second, third] = parents
    unit = delivery(context.binding, parents)
    original = Enum.map(parents, &Jido.Signal.to_map/1)
    before = snapshot()
    {:ok, _} = Instance.subscribe_signals("jido.messaging.membership.observed")
    Process.put({ControlledPersistence, :lookup_failure}, {"bad", :error})

    assert_safe_error(Instance.accept_delivery(unit))
    assert_receive {:signal, first_observed}
    assert Jido.Signal.Context.get(first_observed, "causationid") == first.id
    assert Deduper.count(Instance) == 1
    assert snapshot() == before
    refute_received {:signal, _}

    Process.delete({ControlledPersistence, :lookup_failure})
    assert {:ok, [second_observed, third_observed]} = Instance.accept_delivery(unit)
    assert_receive {:signal, ^second_observed}
    assert_receive {:signal, ^third_observed}
    assert Jido.Signal.Context.get(second_observed, "causationid") == second.id
    assert Jido.Signal.Context.get(third_observed, "causationid") == third.id
    assert Process.get({ControlledPersistence, :lookups}) == ["good", "bad", "bad", "later"]
    assert Deduper.count(Instance) == 3
    assert snapshot() == before
    assert MockTransport.calls(context.transport) == []
    assert Enum.map(parents, &Jido.Signal.to_map/1) == original
    assert {:ok, []} = Instance.accept_delivery(unit)
    refute_received {:signal, _}
  end

  test "a message write error remains private and releases both acceptance claims", context do
    parent =
      MessageReceived.new!(
        %{
          "delivery_id" => "unit",
          "item_id" => "message-item",
          "room_id" => "provider-room",
          "message_id" => "message",
          "sender" => %{"id" => "peer"},
          "text" => "hello"
        },
        source: context.binding.source,
        subject: Identity.conversation_subject(context.binding.id, "provider-room")
      )

    unit = delivery(context.binding, [parent])
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.received")
    Process.put({ControlledPersistence, :write_failure}, true)
    assert_safe_error(Instance.accept_delivery(unit))
    assert Deduper.count(Instance) == 0
    refute_received {:signal, _}

    Process.delete({ControlledPersistence, :write_failure})
    assert {:ok, [received]} = Instance.accept_delivery(unit)
    assert_receive {:signal, ^received}
    assert {:ok, [stored]} = Instance.list_messages(received.data["room_id"])
    assert stored.id == received.data["message_id"]
    assert Process.get({ControlledPersistence, :writes}) == 2
    assert {:ok, []} = Instance.accept_delivery(unit)
    assert Process.get({ControlledPersistence, :writes}) == 2
    assert MockTransport.calls(context.transport) == []
  end

  test "a lifecycle write error has no parent observation and can be retried once", context do
    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:test, context.binding.id, "provider-room", %{type: :group})

    {:ok, message} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: "peer",
        role: :user,
        content: [Jido.Chat.Content.Text.new("before")],
        external_id: "message",
        metadata: %{channel: :test, bridge_id: context.binding.id}
      })

    parent =
      MessageUpdated.new!(
        %{
          "delivery_id" => "unit",
          "item_id" => "update",
          "room_id" => "provider-room",
          "message_id" => "message",
          "text" => "after"
        },
        source: context.binding.source,
        subject: Identity.conversation_subject(context.binding.id, "provider-room")
      )

    unit = delivery(context.binding, [parent])
    {:ok, _} = Instance.subscribe_signals(parent.type)
    Process.put({ControlledPersistence, :write_failure}, true)
    assert_safe_error(Instance.accept_delivery(unit))
    assert {:ok, ^message} = Instance.get_message(message.id)
    assert Deduper.count(Instance) == 0
    refute_received {:signal, _}

    Process.delete({ControlledPersistence, :write_failure})
    assert {:ok, []} = Instance.accept_delivery(unit)
    assert_receive {:signal, ^parent}
    assert {:ok, updated} = Instance.get_message(message.id)
    assert [%Jido.Chat.Content.Text{text: "after"}] = updated.content
    assert Process.get({ControlledPersistence, :writes}) == 3
    assert {:ok, []} = Instance.accept_delivery(unit)
    assert Process.get({ControlledPersistence, :writes}) == 3
    refute_received {:signal, _}
  end
end
