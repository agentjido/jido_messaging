defmodule Jido.Messaging.NativeAutoThreadOutcomeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.Factories, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Messaging.{AgentSupervisor, Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name not in [:save_thread, :save_message] do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_thread(state, thread) do
      if mode = Process.get(:auto_thread_store_failure), do: fail(mode), else: ETS.save_thread(state, thread)
    end

    def save_message(state, message) do
      Process.put(:message_writes, Process.get(:message_writes, 0) + 1)

      if ETS.get_message(state, message.id) == {:error, :not_found},
        do: Process.put(:message_inserts, Process.get(:message_inserts, 0) + 1)

      ETS.save_message(state, message)
    end

    defp fail(:error), do: {:error, :thread_unavailable}
    defp fail(:raise), do: raise("private auto thread store")
    defp fail(:throw), do: throw(:private_auto_thread_store)
    defp fail(:exit), do: exit(:private_auto_thread_store)
    defp fail(:invalid), do: :invalid
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :test
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    @impl true
    def open_thread(room, message, opts) do
      {:ok, _} = MockTransport.request(opts[:transport], :open_thread, %{room: room, message: message}, {:ok, %{}})

      case Process.get(:auto_thread_provider_failure) do
        :error -> {:error, :timeout}
        :raise -> raise "private provider thread"
        :throw -> throw(:private_provider_thread)
        :exit -> exit(:private_provider_thread)
        :invalid -> :invalid
        _ -> {:ok, %{external_thread_id: "thread", delivery_external_room_id: room}}
      end
    end
  end

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "auto-thread", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, room} = Instance.get_or_create_room_by_external_binding(:test, binding.id, "room", %{type: :channel})
    assert {:ok, _} = Instance.register_agent(room.id, %{agent_id: "alpha", handler: fn _, _ -> :noreply end})
    Process.put(:message_writes, 0)
    %{binding: binding, transport: transport, room: room}
  end

  for mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "#{mode} provider thread creation failure retains the accepted whole message and dedupes delivery", context do
      Process.put(:auto_thread_provider_failure, unquote(mode))
      assert_one_acceptance(context)
      assert {:ok, []} = Instance.list_threads(context.room.id)
      assert AgentSupervisor.count_agents(Instance) == 0
      assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
    end

    test "#{mode} thread record failure after one provider open retains the accepted message", context do
      Process.put(:auto_thread_store_failure, unquote(mode))
      assert_one_acceptance(context)
      assert {:ok, []} = Instance.list_threads(context.room.id)
      assert AgentSupervisor.count_agents(Instance) == 0
      assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
    end
  end

  test "ambiguous mentions retain message without selecting either agent or opening a thread", context do
    assert {:ok, _} = Instance.register_agent(context.room.id, %{agent_id: "beta", handler: fn _, _ -> :noreply end})
    assert_one_acceptance(context, "@alpha @beta complete text")
    assert MockTransport.calls(context.transport) == []
    assert AgentSupervisor.count_agents(Instance) == 0
  end

  test "unavailable runner supervisor keeps the accepted message and one unassigned opened thread", context do
    name = Instance.__jido_messaging__(:agent_supervisor)
    pid = Process.whereis(name)
    true = Process.unregister(name)

    try do
      assert_one_acceptance(context, "@alpha complete text", 2)
      assert {:ok, [thread]} = Instance.list_threads(context.room.id)
      assert thread.assigned_agent_id == nil
      assert [%{operation: :open_thread}] = MockTransport.calls(context.transport)
      assert DynamicSupervisor.count_children(pid).active == 0
    after
      true = Process.register(pid, name)
    end
  end

  defp assert_one_acceptance(context, text \\ "@alpha complete text", expected_writes \\ 1) do
    parent =
      Factories.message_received(context.binding, %{
        "delivery_id" => "unit",
        "item_id" => "item",
        "room_id" => "room",
        "message_id" => "message",
        "text" => text,
        "conversation_kind" => "channel"
      })

    original = Jido.Signal.to_map(parent)
    {:ok, delivery} = Delivery.new(context.binding, "unit", [parent])
    assert {:ok, [received]} = Instance.accept_delivery(delivery)
    assert received.data["text"] == text
    assert {:ok, [message]} = Instance.list_messages(context.room.id)
    assert [%Jido.Chat.Content.Text{text: ^text}] = message.content
    assert Process.get(:message_writes) == expected_writes
    assert Process.get(:message_inserts) == 1
    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert Process.get(:message_writes) == expected_writes
    assert Jido.Signal.to_map(parent) == original
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    assert :ets.info(state.principal_grants, :size) == 0
    assert :ets.info(state.memberships, :size) == 0
  end
end
