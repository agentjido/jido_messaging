defmodule Jido.Messaging.MessageLifecycleIngestTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Content.Text
  alias Jido.Messaging.{InboundRouter, Persistence, Runtime}

  defmodule LifecycleAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, %Jido.Chat.Delivery{} = delivery), do: Jido.Chat.Delivery.validate(binding, delivery)

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  test "ETS applies update and delete deliveries without a new inbound message" do
    start_supervised!(ETSMessaging)
    exercise_lifecycle(ETSMessaging)
  end

  test "SQLite applies update and delete deliveries without a new inbound message" do
    path = Path.join(System.tmp_dir!(), "jido-message-lifecycle-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(path) end)

    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})
    exercise_lifecycle(SQLiteMessaging)
  end

  test "ETS updates and deletes the right room when provider IDs repeat" do
    start_supervised!(ETSMessaging)
    exercise_repeated_provider_id(ETSMessaging)
  end

  test "SQLite updates and deletes the right room when provider IDs repeat" do
    path = Path.join(System.tmp_dir!(), "jido-message-scope-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(path) end)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})
    exercise_repeated_provider_id(SQLiteMessaging)
  end

  defp exercise_repeated_provider_id(instance) do
    {:ok, config} = instance.put_bridge_config(%{id: "scope-bridge", adapter_module: LifecycleAdapter})

    {:ok, binding} =
      Runtime.ensure_binding(instance.__jido_messaging__(:runtime), LifecycleAdapter, config.id, bridge_config: config)

    messages =
      for external_room <- ["provider-room-1", "provider-room-2"] do
        {:ok, room} =
          instance.get_or_create_room_by_external_binding(:telegram, config.id, external_room, %{type: :channel})

        {:ok, message} =
          instance.save_message(%{
            room_id: room.id,
            sender_id: "sender",
            role: :user,
            content: [%Text{text: external_room}],
            external_id: "shared-id",
            metadata: %{channel: :telegram, bridge_id: config.id}
          })

        message
      end

    [first, second] = messages
    update = lifecycle_delivery(binding, :message_updated, "shared-id", "updated first")
    assert {:ok, []} = instance.accept_delivery(update)
    assert {:ok, updated} = instance.get_message(first.id)
    assert [%Text{text: "updated first"}] = updated.content
    assert {:ok, ^second} = instance.get_message(second.id)
    assert {:ok, []} = instance.accept_delivery(lifecycle_delivery(binding, :message_deleted, "shared-id", nil))
    assert {:error, :not_found} = instance.get_message(first.id)
    assert {:ok, ^second} = instance.get_message(second.id)
  end

  defp exercise_lifecycle(messaging_module) do
    bridge_id = "bridge_lifecycle"

    {:ok, config} =
      messaging_module.put_bridge_config(%{
        id: bridge_id,
        adapter_module: LifecycleAdapter
      })

    {:ok, binding} =
      Runtime.ensure_binding(messaging_module.__jido_messaging__(:runtime), LifecycleAdapter, bridge_id,
        bridge_config: config
      )

    {:ok, room} =
      messaging_module.get_or_create_room_by_external_binding(:telegram, bridge_id, "provider-room-1", %{
        id: "room:#{inspect(messaging_module)}",
        type: :channel,
        name: "lifecycle"
      })

    {:ok, original} =
      messaging_module.save_message(%{
        id: "message:#{inspect(messaging_module)}",
        room_id: room.id,
        sender_id: "bot:assistant",
        role: :assistant,
        content: [%Text{text: "draft one"}],
        external_id: "provider-message-1",
        status: :sent,
        metadata: %{channel: :telegram, bridge_id: bridge_id, source: :streaming}
      })

    attach_ingest_probes(messaging_module)

    update = lifecycle_delivery(binding, :message_updated, "provider-message-1", "draft two")

    assert {:ok, []} = InboundRouter.route_payload(messaging_module, bridge_id, update)
    assert {:ok, updated} = messaging_module.get_message(original.id)

    assert updated.id == original.id
    assert updated.sender_id == original.sender_id
    assert updated.role == :assistant
    assert updated.external_id == original.external_id
    assert [%Text{text: "draft two"}] = updated.content

    assert {:ok, ^updated} = messaging_module.get_message(original.id)
    assert {:ok, [^updated]} = messaging_module.list_messages(room.id)

    assert {:ok, []} = InboundRouter.route_payload(messaging_module, bridge_id, update)
    assert {:ok, duplicate_update} = messaging_module.get_message(original.id)

    assert duplicate_update.id == original.id
    assert duplicate_update.role == :assistant
    assert [%Text{text: "draft two"}] = duplicate_update.content
    assert duplicate_update == updated
    assert {:ok, [_one_message]} = messaging_module.list_messages(room.id)

    missing_update = lifecycle_delivery(binding, :message_updated, "missing-message", "not stored")

    assert {:ok, []} =
             InboundRouter.route_payload(messaging_module, bridge_id, missing_update)

    delete = lifecycle_delivery(binding, :message_deleted, "provider-message-1", nil)

    assert {:ok, []} = InboundRouter.route_payload(messaging_module, bridge_id, delete)
    assert {:error, :not_found} = messaging_module.get_message(original.id)

    assert {:error, :not_found} =
             messaging_module.get_message_by_external_id(:telegram, bridge_id, original.external_id)

    assert {:ok, []} = messaging_module.list_messages(room.id)

    assert_external_id_index_removed(messaging_module, bridge_id, original)

    assert {:ok, []} =
             InboundRouter.route_payload(messaging_module, bridge_id, delete)

    missing_delete = lifecycle_delivery(binding, :message_deleted, "another-missing-message", nil)

    assert {:ok, []} =
             InboundRouter.route_payload(messaging_module, bridge_id, missing_delete)

    refute_received {:normal_ingest_signal, _event, _metadata}
  end

  defp assert_external_id_index_removed(ETSMessaging, bridge_id, original) do
    {Persistence.ETS, state} = Runtime.get_persistence(ETSMessaging.__jido_messaging__(:runtime))
    key = {:telegram, bridge_id, original.external_id}

    assert [] = :ets.lookup(state.message_external_ids, key)
  end

  defp assert_external_id_index_removed(_messaging_module, _bridge_id, _original), do: :ok

  defp lifecycle_delivery(binding, type, id, text) do
    identity = "delivery:#{type}:#{id}"

    data = %{
      "item_id" => identity,
      "delivery_id" => identity,
      "room_id" => "provider-room-1",
      "message_id" => id,
      "timestamp" => "2026-08-20T12:00:00Z"
    }

    definition = if type == :message_updated, do: Jido.Chat.Signal.MessageUpdated, else: Jido.Chat.Signal.MessageDeleted
    data = if text, do: Map.put(data, "text", text), else: data

    signal =
      definition.new!(data,
        source: binding.source,
        subject: Jido.Chat.Signal.Identity.conversation_subject(binding.id, "provider-room-1")
      )

    {:ok, delivery} = Jido.Chat.Delivery.new(binding, identity, [signal])
    delivery
  end

  defp attach_ingest_probes(messaging_module) do
    handler_id = "message-lifecycle-#{inspect(messaging_module)}-#{System.unique_integer([:positive])}"
    test_pid = self()

    for event <- [
          [:jido_messaging, :message, :received],
          [:jido_messaging, :room, :message_added]
        ] do
      id = "#{handler_id}-#{Enum.join(event, "-")}"

      :ok =
        :telemetry.attach(
          id,
          event,
          fn observed_event, _measurements, metadata, pid ->
            if metadata[:instance_module] == messaging_module do
              send(pid, {:normal_ingest_signal, observed_event, metadata})
            end
          end,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(id) end)
    end
  end
end
