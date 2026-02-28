defmodule Jido.Messaging.AuditLogger do
  @moduledoc """
  Telemetry-based audit logging for Jido.Messaging events.

  Attaches to telemetry events and logs them using Elixir's Logger.
  Provides structured audit trails for all significant messaging events.

  ## Usage

      # Attach to all events with default settings
      Jido.Messaging.AuditLogger.attach()

      # Attach with options
      Jido.Messaging.AuditLogger.attach(
        log_level: :info,
        include_typing: false,  # Don't log typing events (can be noisy)
        prefix: "audit"
      )

      # Detach when no longer needed
      Jido.Messaging.AuditLogger.detach()

  ## Logged Events

  All events are logged with structured metadata including:
  - `room_id` - the room where the event occurred
  - `instance_module` - the messaging module
  - `timestamp` - when the event occurred
  - `correlation_id` - for tracing related events

  ### Message Events
  - `[:jido_messaging, :message, :received]`
  - `[:jido_messaging, :message, :sent]`
  - `[:jido_messaging, :message, :failed]`
  - `[:jido_messaging, :message, :delivered]`
  - `[:jido_messaging, :message, :read]`
  - `[:jido_messaging, :message, :reaction_added]`
  - `[:jido_messaging, :message, :reaction_removed]`

  ### Participant Events
  - `[:jido_messaging, :participant, :presence_changed]`
  - `[:jido_messaging, :participant, :typing]` (optional, disabled by default)

  ### Thread Events
  - `[:jido_messaging, :thread, :created]`
  - `[:jido_messaging, :thread, :reply_added]`
  """

  require Logger

  @handler_id "jido_messaging_audit_logger"

  @message_events [
    [:jido_messaging, :message, :received],
    [:jido_messaging, :message, :sent],
    [:jido_messaging, :message, :failed],
    [:jido_messaging, :message, :delivered],
    [:jido_messaging, :message, :read],
    [:jido_messaging, :message, :reaction_added],
    [:jido_messaging, :message, :reaction_removed]
  ]

  @participant_events [
    [:jido_messaging, :participant, :presence_changed]
  ]

  @typing_events [
    [:jido_messaging, :participant, :typing]
  ]

  @thread_events [
    [:jido_messaging, :thread, :created],
    [:jido_messaging, :thread, :reply_added]
  ]

  @doc """
  Attach the audit logger to all Jido.Messaging telemetry events.

  ## Options

  - `:log_level` - Logger level to use (default: `:info`)
  - `:include_typing` - Whether to log typing events (default: `false`)
  - `:prefix` - Prefix for log messages (default: `"Jido.Messaging.Audit"`)
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    include_typing = Keyword.get(opts, :include_typing, false)

    events =
      @message_events ++
        @participant_events ++
        @thread_events ++
        if(include_typing, do: @typing_events, else: [])

    config = %{
      log_level: Keyword.get(opts, :log_level, :info),
      prefix: Keyword.get(opts, :prefix, "Jido.Messaging.Audit")
    }

    :telemetry.attach_many(
      @handler_id,
      events,
      &__MODULE__.handle_event/4,
      config
    )
  end

  @doc """
  Detach the audit logger from telemetry events.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(event_name, measurements, metadata, config) do
    log_level = config.log_level
    prefix = config.prefix

    {event_type, log_message, log_metadata} = format_event(event_name, measurements, metadata)

    Logger.log(log_level, "[#{prefix}] #{event_type}: #{log_message}", log_metadata)
  end

  defp format_event([:jido_messaging, :message, :received], _measurements, metadata) do
    msg = "Message received in room #{metadata.room_id} from #{metadata.participant_id}"

    log_meta = [
      room_id: metadata.room_id,
      message_id: metadata.message.id,
      sender_id: metadata.participant_id,
      correlation_id: metadata.correlation_id
    ]

    {"message.received", msg, log_meta}
  end

  defp format_event([:jido_messaging, :message, :sent], _measurements, metadata) do
    msg = "Message sent to room #{metadata.room_id}"

    log_meta = [
      room_id: metadata.room_id,
      message_id: metadata.message.id,
      correlation_id: metadata.correlation_id
    ]

    {"message.sent", msg, log_meta}
  end

  defp format_event([:jido_messaging, :message, :failed], _measurements, metadata) do
    msg = "Message delivery failed in room #{metadata.room_id}: #{inspect(metadata.reason)}"

    log_meta = [
      room_id: metadata.room_id,
      reason: metadata.reason,
      correlation_id: metadata.correlation_id
    ]

    {"message.failed", msg, log_meta}
  end

  defp format_event([:jido_messaging, :message, :delivered], _measurements, metadata) do
    msg = "Message #{metadata.message_id} delivered to #{metadata.participant_id}"

    log_meta = [
      room_id: metadata.room_id,
      message_id: metadata.message_id,
      participant_id: metadata.participant_id,
      correlation_id: metadata.correlation_id
    ]

    {"message.delivered", msg, log_meta}
  end

  defp format_event([:jido_messaging, :message, :read], _measurements, metadata) do
    msg = "Message #{metadata.message_id} read by #{metadata.participant_id}"

    log_meta = [
      room_id: metadata.room_id,
      message_id: metadata.message_id,
      participant_id: metadata.participant_id,
      correlation_id: metadata.correlation_id
    ]

    {"message.read", msg, log_meta}
  end

  defp format_event([:jido_messaging, :message, :reaction_added], _measurements, metadata) do
    msg = "Reaction '#{metadata.reaction}' added to message #{metadata.message_id} by #{metadata.participant_id}"

    log_meta = [
      room_id: metadata.room_id,
      message_id: metadata.message_id,
      participant_id: metadata.participant_id,
      reaction: metadata.reaction,
      correlation_id: metadata.correlation_id
    ]

    {"message.reaction_added", msg, log_meta}
  end

  defp format_event([:jido_messaging, :message, :reaction_removed], _measurements, metadata) do
    msg = "Reaction '#{metadata.reaction}' removed from message #{metadata.message_id} by #{metadata.participant_id}"

    log_meta = [
      room_id: metadata.room_id,
      message_id: metadata.message_id,
      participant_id: metadata.participant_id,
      reaction: metadata.reaction,
      correlation_id: metadata.correlation_id
    ]

    {"message.reaction_removed", msg, log_meta}
  end

  defp format_event([:jido_messaging, :participant, :presence_changed], _measurements, metadata) do
    msg = "Participant #{metadata.participant_id} presence changed from #{metadata.from} to #{metadata.to}"

    log_meta = [
      room_id: metadata.room_id,
      participant_id: metadata.participant_id,
      from: metadata.from,
      to: metadata.to,
      correlation_id: metadata.correlation_id
    ]

    {"participant.presence_changed", msg, log_meta}
  end

  defp format_event([:jido_messaging, :participant, :typing], _measurements, metadata) do
    action = if metadata.is_typing, do: "started", else: "stopped"
    thread_info = if metadata.thread_root_id, do: " in thread #{metadata.thread_root_id}", else: ""
    msg = "Participant #{metadata.participant_id} #{action} typing#{thread_info}"

    log_meta = [
      room_id: metadata.room_id,
      participant_id: metadata.participant_id,
      is_typing: metadata.is_typing,
      thread_root_id: metadata.thread_root_id,
      correlation_id: metadata.correlation_id
    ]

    {"participant.typing", msg, log_meta}
  end

  defp format_event([:jido_messaging, :thread, :created], _measurements, metadata) do
    msg = "Thread created from message #{metadata.root_message_id}"

    log_meta = [
      room_id: metadata.room_id,
      root_message_id: metadata.root_message_id,
      correlation_id: metadata.correlation_id
    ]

    {"thread.created", msg, log_meta}
  end

  defp format_event([:jido_messaging, :thread, :reply_added], _measurements, metadata) do
    msg = "Reply #{metadata.message_id} added to thread #{metadata.root_message_id}"

    log_meta = [
      room_id: metadata.room_id,
      root_message_id: metadata.root_message_id,
      message_id: metadata.message_id,
      correlation_id: metadata.correlation_id
    ]

    {"thread.reply_added", msg, log_meta}
  end

  defp format_event(event_name, _measurements, metadata) do
    event_str = Enum.join(event_name, ".")
    msg = "Event in room #{metadata[:room_id]}"

    log_meta = [
      room_id: metadata[:room_id],
      correlation_id: metadata[:correlation_id]
    ]

    {event_str, msg, log_meta}
  end
end
