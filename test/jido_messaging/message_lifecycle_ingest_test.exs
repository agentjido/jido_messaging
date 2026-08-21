defmodule Jido.Messaging.MessageLifecycleIngestTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Content.Text
  alias Jido.Chat.EventEnvelope
  alias Jido.Messaging.{InboundRouter, Persistence, Runtime}

  defmodule LifecycleAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def transform_incoming(_payload), do: {:error, :unsupported_payload}

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

  defp exercise_lifecycle(messaging_module) do
    bridge_id = "bridge_lifecycle"

    {:ok, _bridge} =
      messaging_module.put_bridge_config(%{
        id: bridge_id,
        adapter_module: LifecycleAdapter
      })

    {:ok, room} =
      messaging_module.create_room(%{
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

    update = lifecycle_envelope(:message_updated, "provider-message-1", "draft two")

    assert {:ok, {:message_updated, updated, %EventEnvelope{event_type: :message_updated}}} =
             InboundRouter.route_payload(messaging_module, bridge_id, update)

    assert updated.id == original.id
    assert updated.sender_id == original.sender_id
    assert updated.role == :assistant
    assert updated.external_id == original.external_id
    assert [%Text{text: "draft two"}] = updated.content

    assert {:ok, ^updated} = messaging_module.get_message(original.id)
    assert {:ok, [^updated]} = messaging_module.list_messages(room.id)

    assert {:ok, {:message_updated, duplicate_update, %EventEnvelope{}}} =
             InboundRouter.route_payload(messaging_module, bridge_id, update)

    assert duplicate_update.id == original.id
    assert duplicate_update.role == :assistant
    assert [%Text{text: "draft two"}] = duplicate_update.content
    assert duplicate_update == updated
    assert {:ok, [_one_message]} = messaging_module.list_messages(room.id)

    missing_update = lifecycle_envelope(:message_updated, "missing-message", "not stored")

    assert {:ok, {:message_not_found, %EventEnvelope{event_type: :message_updated}}} =
             InboundRouter.route_payload(messaging_module, bridge_id, missing_update)

    delete = lifecycle_envelope(:message_deleted, "provider-message-1", nil)

    assert {:ok, {:message_deleted, deleted, %EventEnvelope{event_type: :message_deleted}}} =
             InboundRouter.route_payload(messaging_module, bridge_id, delete)

    assert deleted.id == original.id
    assert deleted.role == :assistant
    assert deleted.sender_id == original.sender_id
    assert {:error, :not_found} = messaging_module.get_message(original.id)

    assert {:error, :not_found} =
             messaging_module.get_message_by_external_id(:telegram, bridge_id, original.external_id)

    assert {:ok, []} = messaging_module.list_messages(room.id)

    assert_external_id_index_removed(messaging_module, bridge_id, original)

    assert {:ok, {:message_not_found, %EventEnvelope{event_type: :message_deleted}}} =
             InboundRouter.route_payload(messaging_module, bridge_id, delete)

    missing_delete = lifecycle_envelope(:message_deleted, "another-missing-message", nil)

    assert {:ok, {:message_not_found, %EventEnvelope{event_type: :message_deleted}}} =
             InboundRouter.route_payload(messaging_module, bridge_id, missing_delete)

    refute_received {:normal_ingest_signal, _event, _metadata}
  end

  defp assert_external_id_index_removed(ETSMessaging, bridge_id, original) do
    {Persistence.ETS, state} = Runtime.get_persistence(ETSMessaging.__jido_messaging__(:runtime))
    key = {:telegram, bridge_id, original.external_id}

    assert [] = :ets.lookup(state.message_external_ids, key)
  end

  defp assert_external_id_index_removed(_messaging_module, _bridge_id, _original), do: :ok

  defp lifecycle_envelope(event_type, message_id, text) do
    message =
      if is_binary(text) do
        %{
          id: message_id,
          external_message_id: message_id,
          text: text,
          updated_at: "2026-08-20T12:00:00Z"
        }
      end

    %{
      id: "delivery:#{event_type}:#{message_id}",
      adapter_name: :telegram,
      event_type: event_type,
      thread_id: "telegram:provider-room-1",
      channel_id: "provider-room-1",
      message_id: message_id,
      payload: %{
        adapter_name: :telegram,
        thread_id: "telegram:provider-room-1",
        channel_id: "provider-room-1",
        message_id: message_id,
        message: message,
        author: %{
          user_id: "provider-bot-1",
          user_name: "assistant",
          is_bot: true,
          is_me: true
        },
        timestamp: "2026-08-20T12:00:00Z",
        metadata: %{delivery_id: "delivery:#{event_type}:#{message_id}"},
        raw: %{provider: "telegram"}
      },
      raw: %{provider: "telegram"},
      metadata: %{source: :listener}
    }
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
