defmodule Jido.Messaging.NativeAuditLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Jido.Chat.{Content.Text, Participant}
  alias Jido.Messaging.{AuditLogger, Message, RoomServer, Signal}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{id: "audit-room", type: :group})
    {:ok, server} = Jido.Messaging.RoomSupervisor.get_or_start_room(Instance, room)
    on_exit(fn -> AuditLogger.detach() end)
    %{room: room, server: server}
  end

  test "native message emission keeps audit handler and direct Signal identity", context do
    assert :ok = AuditLogger.attach(log_level: :info, prefix: "NativeAudit")
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.**")
    message = message("root")

    parent =
      Jido.Messaging.Signal.PostMessage.new!(%{
        "request_id" => "parent",
        "room_id" => context.room.id,
        "sender_id" => "sender",
        "text" => "text"
      })

    before = Jido.Signal.to_map(parent)

    log =
      capture_log([metadata: [:room_id, :message_id, :signal_id, :causation_id]], fn ->
        assert :ok = Signal.emit_received(message, %{instance_module: Instance, parent_signal: parent})
        assert :ok = Signal.emit_sent(message, %{instance_module: Instance, parent_signal: parent})
      end)

    assert log =~ "[NativeAudit] message.received"
    assert log =~ "[NativeAudit] message.sent"
    assert log =~ "room_id=audit-room"
    assert log =~ "message_id=root"
    assert log =~ "causation_id=#{parent.id}"
    assert handler_attached?([:jido_messaging, :message, :received])
    assert_receive {:signal, received}
    assert_receive {:signal, sent}
    assert received.type == "jido.messaging.message.received"
    assert sent.type == "jido.messaging.message.sent"
    assert log =~ "signal_id=#{received.id}"
    assert Jido.Signal.Context.get(received, "causationid") == parent.id
    assert Jido.Signal.Trace.get(received).trace_id == Jido.Signal.Trace.get(parent).trace_id
    assert Jido.Signal.to_map(parent) == before
    refute Map.has_key?(received.extensions, "correlationid")
  end

  test "room receipt reaction presence typing and thread operations keep the audit handler", context do
    assert :ok = AuditLogger.attach(log_level: :info, include_typing: true)
    sender = Participant.new(%{id: "sender", type: :human})
    reader = Participant.new(%{id: "reader", type: :human})
    root = message("root")
    reply = message("reply")

    log =
      capture_log(fn ->
        assert :ok = RoomServer.add_participant(context.server, sender)
        assert :ok = RoomServer.add_participant(context.server, reader)
        assert :ok = RoomServer.add_message(context.server, root)
        assert {:ok, _} = RoomServer.mark_delivered(context.server, root.id, reader.id)
        assert {:ok, _} = RoomServer.mark_read(context.server, root.id, reader.id)
        assert {:ok, _} = RoomServer.add_reaction(context.server, root.id, reader.id, "+1")
        assert {:ok, _} = RoomServer.remove_reaction(context.server, root.id, reader.id, "+1")
        assert :ok = RoomServer.update_presence(context.server, reader.id, :online)
        assert :ok = RoomServer.set_typing(context.server, reader.id, true, thread_id: "root")
        assert :ok = RoomServer.set_typing(context.server, reader.id, false, thread_id: "root")
        assert {:ok, _} = GenServer.call(context.server, {:create_thread, root.id})
        assert {:ok, _} = GenServer.call(context.server, {:add_thread_reply, root.id, reply})
      end)

    for event <-
          ~w(message.delivered message.read message.reaction_added message.reaction_removed participant.presence_changed participant.typing thread.created thread.reply_added),
        do: assert(log =~ event)

    assert log =~ "started typing in thread root"
    assert log =~ "stopped typing in thread root"
    assert log =~ "from offline to online"
    assert handler_attached?([:jido_messaging, :thread, :reply_added])
    assert [reply_record, root_record] = RoomServer.get_messages(context.server)
    assert reply_record.thread_id == root.id
    assert root_record.status == :read
  end

  test "native failure audit logs the safe code and excludes private error payload", context do
    assert :ok = AuditLogger.attach(log_level: :warning)
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.failed")

    log =
      capture_log(fn ->
        assert :ok =
                 Signal.emit_failed(context.room.id, {:provider_error, %{token: "private-error-value"}}, %{
                   instance_module: Instance,
                   message_id: "root"
                 })
      end)

    assert log =~ "message.failed"
    refute log =~ "private-error-value"
    assert handler_attached?([:jido_messaging, :message, :failed])
    assert_receive {:signal, failure}
    assert log =~ failure.data["code"]
    refute Jason.encode!(Jido.Signal.to_map(failure)) =~ "private-error-value"
  end

  defp handler_attached?(event),
    do: Enum.any?(:telemetry.list_handlers(event), &(&1.id == "jido_messaging_audit_logger"))

  defp message(id),
    do:
      Message.new(%{
        id: id,
        room_id: "audit-room",
        sender_id: "sender",
        role: :user,
        status: :sent,
        content: [Text.new(id)]
      })
end
