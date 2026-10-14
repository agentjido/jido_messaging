defmodule Jido.Messaging.ProviderFactObservationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Chat.Signal.Identity
  alias Jido.Messaging.{AgentRunner, Runtime}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  @catalog Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/catalog.json")
           |> File.read!()
           |> Jason.decode!()
  @observations Enum.filter(@catalog["definitions"], fn entry ->
                  entry["owner"] == "chat" and entry["kind"] == "fact" and
                    entry["type"] not in ~w(jido.chat.message.received jido.chat.message.updated jido.chat.message.deleted jido.chat.membership.changed)
                end)

  setup do
    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "observed-binding", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)

    {:ok, room} =
      Instance.get_or_create_room_by_external_binding(:test, binding.id, "room/1", %{type: :group})

    {:ok, participant} =
      Instance.get_or_create_participant_by_external_id(:test, binding.id, "actor-1", %{type: :human})

    {:ok, thread} = Instance.save_thread(%{room_id: room.id, external_thread_id: "thread-1"})
    owner = self()

    {:ok, _} =
      Instance.register_agent(room.id, %{
        agent_id: "alpha",
        name: "Alpha",
        handler: fn _message, _context ->
          send(owner, :agent_handled)
          :noreply
        end
      })

    {:ok, _} = Instance.assign_thread(room.id, thread.id, "alpha")
    runner = AgentRunner.whereis(Instance, room.id, thread.id, "alpha")
    assert is_pid(runner)
    _ = :sys.get_state(runner)

    {:ok, _} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: participant.id,
        thread_id: thread.id,
        role: :user,
        status: :sent,
        content: [Jido.Chat.Content.Text.new("stored")],
        external_id: "message-1",
        metadata: %{channel: :test, bridge_id: binding.id},
        reactions: %{"thumbsup" => [participant.id]}
      })

    {:ok, _} = Instance.subscribe_signals("jido.chat.**")
    {:ok, _} = Instance.subscribe_signals("jido.messaging.**")
    %{binding: binding, transport: transport, runner: runner}
  end

  test "provider observations retain their external context and do not infer runtime commands", context do
    assert length(@observations) == 13
    before = storage_snapshot()

    parents =
      for entry <- @observations do
        definition = Module.concat([entry["module"]])
        data = entry["fixture"] |> Map.put("delivery_id", "observations") |> Map.put("item_id", entry["type"])

        definition.new!(data,
          source: context.binding.source,
          subject: Identity.conversation_subject(context.binding.id, data["room_id"])
        )
      end

    {:ok, delivery} = Delivery.new(context.binding, "observations", parents)
    assert {:ok, []} = Instance.accept_delivery(delivery)

    for parent <- parents do
      assert_receive {:signal, ^parent}
      assert parent.source == context.binding.source
      assert parent.subject == Identity.conversation_subject(context.binding.id, parent.data["room_id"])
      assert {:ok, json} = Jido.Signal.Serialization.serialize(parent)
      {:ok, catalog} = Runtime.catalog(Instance.__jido_messaging__(:runtime))
      assert {:ok, ^parent} = Jido.Signal.Catalog.decode(catalog, json)
    end

    _ = :sys.get_state(context.runner)
    assert storage_snapshot() == before
    assert MockTransport.calls(context.transport) == []
    refute_received :agent_handled
    refute_receive {:signal, _}

    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert storage_snapshot() == before
    assert MockTransport.calls(context.transport) == []
    refute_receive {:signal, _}
  end

  defp storage_snapshot do
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))

    for {name, table} <- Map.to_list(state), is_reference(table), :ets.info(table) != :undefined, into: %{} do
      {name, table |> :ets.tab2list() |> Enum.sort()}
    end
  end
end
