defmodule Jido.Messaging.IngestThreadAdmissionTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Chat.Signal.{Identity, MessageReceived}
  alias Jido.Messaging.{Ingest, Runtime}

  defmodule ControlledPersistence do
    @behaviour Jido.Messaging.Persistence

    for {name, arity} <- Jido.Messaging.Persistence.ETS.__info__(:functions), name != :save_message do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: Jido.Messaging.Persistence.ETS
    end

    def save_message(state, message) do
      Process.put({__MODULE__, :save_count}, Process.get({__MODULE__, :save_count}, 0) + 1)

      case Process.get({__MODULE__, :save_modes}, []) do
        [:fail | rest] ->
          Process.put({__MODULE__, :save_modes}, rest)
          {:error, :store_unavailable}

        modes ->
          Process.put({__MODULE__, :save_modes}, Enum.drop(modes, 1))
          Jido.Messaging.Persistence.ETS.save_message(state, message)
      end
    end
  end

  defmodule Instance do
    use Jido.Messaging,
      persistence: Jido.Messaging.IngestThreadAdmissionTest.ControlledPersistence,
      runtime_profile: :core
  end

  defmodule DenyGater do
    @behaviour Jido.Messaging.Gating
    @impl true
    def check(_context, _opts), do: {:deny, :denied, "Message denied"}
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "thread-binding", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)

    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:test, binding.id, "provider-room", %{type: :channel})

    test_pid = self()

    {:ok, _} =
      Instance.register_agent(room.id, %{
        agent_id: "alpha",
        name: "Alpha",
        handler: fn _message, _context ->
          send(test_pid, :agent_handled)
          :noreply
        end
      })

    incoming = %{
      external_room_id: "provider-room",
      external_message_id: "provider-message",
      external_user_id: "peer",
      text: "@alpha please handle this",
      chat_type: :channel
    }

    parent =
      MessageReceived.new!(
        %{
          "delivery_id" => "provider-delivery",
          "item_id" => "provider-item",
          "room_id" => incoming.external_room_id,
          "message_id" => incoming.external_message_id,
          "sender" => %{"id" => incoming.external_user_id},
          "text" => incoming.text,
          "conversation_kind" => "channel"
        },
        source: binding.source,
        subject: Identity.conversation_subject(binding.id, incoming.external_room_id)
      )

    {:ok, delivery} = Delivery.new(binding, "provider-delivery", [parent])
    %{room: room, binding: binding, transport: transport, incoming: incoming, parent: parent, delivery: delivery}
  end

  test "a policy denial causes no thread callback or message write", context do
    assert {:error, {:policy_denied, :gating, :denied, "Message denied"}} =
             Ingest.ingest_incoming(Instance, MockAdapter, context.binding.id, context.incoming,
               gaters: [DenyGater],
               parent_signal: context.parent
             )

    assert MockTransport.calls(context.transport) == []
    assert Process.get({ControlledPersistence, :save_count}, 0) == 0
    assert {:ok, []} = Instance.list_messages(context.room.id)
    assert {:ok, []} = Instance.list_threads(context.room.id)
    refute_received :agent_handled
  end

  test "failed initial storage causes no callback; a successful retry opens one thread", context do
    Process.put({ControlledPersistence, :save_modes}, [:fail])
    assert {:error, %Jido.Chat.Errors.Contract{code: :handler_failed}} = Instance.accept_delivery(context.delivery)
    assert MockTransport.calls(context.transport) == []
    assert {:ok, []} = Instance.list_messages(context.room.id)
    assert {:ok, []} = Instance.list_threads(context.room.id)

    assert {:ok, [accepted]} = Instance.accept_delivery(context.delivery)
    assert accepted.data["thread_id"]
    assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
    assert {:ok, []} = Instance.accept_delivery(context.delivery)
    assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
    assert {:ok, [_one_message]} = Instance.list_messages(context.room.id)
    assert {:ok, [_one_thread]} = Instance.list_threads(context.room.id)
  end

  test "the provider sees a committed message before automatic thread creation", context do
    owner = self()

    :ok =
      MockTransport.stub(context.transport, :open_thread, fn _request ->
        send(owner, {:stored_before_callback, Instance.list_messages(context.room.id)})
        {:ok, %{external_thread_id: "confirmed-thread", delivery_external_room_id: "provider-room"}}
      end)

    assert {:ok, [accepted]} = Instance.accept_delivery(context.delivery)
    assert_receive {:stored_before_callback, {:ok, [stored_before]}}
    assert stored_before.id == accepted.data["message_id"]
    assert stored_before.thread_id == nil
    assert accepted.data["thread_id"]
    assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
  end

  test "failed thread-link storage reports the accepted message and does not repeat the provider", context do
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.failed")
    Process.put({ControlledPersistence, :save_modes}, [:pass, :fail])

    assert {:ok, [accepted]} = Instance.accept_delivery(context.delivery)
    assert_receive {:signal, failure}
    assert failure.data["code"] == "persistence_failed"
    assert failure.data["message_id"] == accepted.data["message_id"]
    assert Jido.Signal.Context.get(failure, "causationid") == context.parent.id
    assert Jido.Signal.Trace.get(failure).trace_id == Jido.Signal.Trace.get(context.parent).trace_id
    assert {:ok, stored} = Instance.get_message(accepted.data["message_id"])
    assert stored.thread_id == nil
    assert accepted.data["thread_id"] == nil
    assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)

    assert {:ok, []} = Instance.accept_delivery(context.delivery)
    assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
    assert {:ok, [_one_message]} = Instance.list_messages(context.room.id)
    refute_received :agent_handled
    refute_receive {:signal, _}
  end
end
