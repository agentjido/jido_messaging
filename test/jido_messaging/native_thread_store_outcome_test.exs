defmodule Jido.Messaging.NativeThreadStoreOutcomeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.Factories, AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Messaging.{Deduper, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name not in [:save_thread, :save_message] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_thread(state, thread) do
      Process.put(:thread_attempts, Process.get(:thread_attempts, 0) + 1)
      if mode = Process.get(:thread_failure), do: fail(mode), else: ETS.save_thread(state, thread)
    end

    def save_message(state, message) do
      Process.put(:message_writes, Process.get(:message_writes, 0) + 1)
      result = ETS.save_message(state, message)
      if mode = Process.get(:thread_failure_after_message), do: Process.put(:thread_failure, mode)
      result
    end

    defp fail(:error), do: {:error, :thread_store_unavailable}
    defp fail(:raise), do: raise("private thread store error")
    defp fail(:throw), do: throw(:private_thread_store_error)
    defp fail(:exit), do: exit(:private_thread_store_error)
    defp fail(:invalid), do: :invalid
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "thread-outcome", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, room} = Instance.get_or_create_room_by_external_binding(:test, binding.id, "room", %{type: :group})
    {:ok, thread} = Instance.save_thread(%{room_id: room.id, external_thread_id: "provider-thread"})
    %{binding: binding, room: room, thread: thread, transport: transport}
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{mode} thread backfill after message write keeps acceptance and emits one causal failure", context do
      Process.put(:thread_failure_after_message, unquote(mode))
      Process.put(:message_writes, 0)
      {:ok, _} = Instance.subscribe_signals("jido.messaging.message.**")
      parent = parent(context.binding)
      original = Jido.Signal.to_map(parent)
      {:ok, delivery} = Delivery.new(context.binding, "unit", [parent])
      assert {:ok, [received]} = Instance.accept_delivery(delivery)
      assert_receive {:signal, failure}
      assert failure.type == "jido.messaging.message.failed"
      assert failure.data["code"] == "persistence_failed"
      assert Jido.Signal.Context.get(failure, "causationid") == parent.id
      assert_receive {:signal, ^received}
      assert Process.get(:message_writes) == 1
      assert {:ok, [message]} = Instance.list_messages(context.room.id)
      assert message.id == received.data["message_id"]
      assert [%Jido.Chat.Content.Text{text: "complete threaded message"}] = message.content
      assert message.thread_id == context.thread.id
      assert {:ok, []} = Instance.accept_delivery(delivery)
      assert Process.get(:message_writes) == 1
      assert MockTransport.calls(context.transport) == []
      assert Jido.Signal.to_map(parent) == original
      refute_receive {:signal, _}
    end
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{mode} existing-thread merge rejects before a canonical message write and permits one retry", context do
      Process.put(:thread_failure, unquote(mode))
      Process.put(:message_writes, 0)
      parent = parent(context.binding)
      original = Jido.Signal.to_map(parent)
      {:ok, delivery} = Delivery.new(context.binding, "unit", [parent])
      assert {:error, %Jido.Chat.Errors.Contract{}} = Instance.accept_delivery(delivery)
      assert Process.get(:message_writes) == 0
      assert {:ok, []} = Instance.list_messages(context.room.id)
      assert {:ok, stored} = Instance.get_thread(context.thread.id)
      assert stored == context.thread
      assert Deduper.count(Instance) == 0
      Process.delete(:thread_failure)
      assert {:ok, [_]} = Instance.accept_delivery(delivery)
      assert Process.get(:message_writes) == 1
      assert {:ok, [message]} = Instance.list_messages(context.room.id)
      assert [%Jido.Chat.Content.Text{text: "complete threaded message"}] = message.content
      assert message.thread_id == context.thread.id
      assert {:ok, []} = Instance.accept_delivery(delivery)
      assert Process.get(:message_writes) == 1
      assert MockTransport.calls(context.transport) == []
      assert Jido.Signal.to_map(parent) == original
    end
  end

  defp parent(binding) do
    Factories.message_received(binding, %{
      "delivery_id" => "unit",
      "item_id" => "item",
      "room_id" => "room",
      "message_id" => "message",
      "text" => "complete threaded message",
      "thread_id" => "provider-thread"
    })
  end
end
