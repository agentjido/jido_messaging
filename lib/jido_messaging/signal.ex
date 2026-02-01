defmodule JidoMessaging.Signal do
  @moduledoc """
  Signal emission for messaging events using Elixir's built-in `:telemetry`.

  Provides telemetry-style events for message lifecycle:
  - `[:jido_messaging, :message, :received]` - when a message is ingested
  - `[:jido_messaging, :message, :sent]` - when a message is delivered successfully
  - `[:jido_messaging, :message, :failed]` - when delivery fails

  ## Usage

  To attach a handler for these events:

      :telemetry.attach(
        "my-handler",
        [:jido_messaging, :message, :received],
        &MyHandler.handle_event/4,
        nil
      )

  Each event includes measurements `%{timestamp: DateTime.t()}` and metadata
  containing the message, room_id, and event-specific information.

  ## Standard Metadata Keys

  All signals include a consistent set of metadata keys for correlation and tracing.
  See `@metadata_keys` for the standard keys included in all events.
  """

  @metadata_keys [
    :instance_module,
    :room_id,
    :instance_id,
    :timestamp,
    :correlation_id
  ]

  @doc """
  Returns the list of standard metadata keys included in all signals.
  """
  @spec metadata_keys() :: [atom()]
  def metadata_keys, do: @metadata_keys

  @doc """
  Emits a `:received` signal when a message has been ingested.

  ## Metadata
  - `:message` - the ingested `JidoMessaging.Message` struct
  - `:room_id` - the room ID where the message was received
  - `:participant_id` - the sender's participant ID
  - `:channel` - the channel module that received the message
  - `:instance_id` - the instance ID of the channel
  - `:instance_module` - the messaging module
  - `:timestamp` - when the event occurred
  - `:correlation_id` - message ID or generated ID for tracing
  """
  @spec emit_received(JidoMessaging.Message.t(), map()) :: :ok
  def emit_received(message, context) do
    timestamp = DateTime.utc_now()
    correlation_id = message.id || generate_correlation_id()

    :telemetry.execute(
      [:jido_messaging, :message, :received],
      %{timestamp: timestamp},
      %{
        message: message,
        room_id: message.room_id,
        participant_id: message.sender_id,
        channel: context[:channel],
        instance_id: context[:instance_id],
        instance_module: context[:instance_module],
        timestamp: timestamp,
        correlation_id: correlation_id
      }
    )
  end

  @doc """
  Emits a `:sent` signal when a message has been delivered successfully.

  ## Metadata
  - `:message` - the sent `JidoMessaging.Message` struct
  - `:room_id` - the room ID where the message was sent
  - `:channel` - the channel module used for delivery
  - `:external_room_id` - the external room identifier
  - `:instance_module` - the messaging module
  - `:instance_id` - the instance ID
  - `:timestamp` - when the event occurred
  - `:correlation_id` - message ID or generated ID for tracing
  """
  @spec emit_sent(JidoMessaging.Message.t(), map()) :: :ok
  def emit_sent(message, context) do
    timestamp = DateTime.utc_now()
    correlation_id = message.id || generate_correlation_id()

    :telemetry.execute(
      [:jido_messaging, :message, :sent],
      %{timestamp: timestamp},
      %{
        message: message,
        room_id: message.room_id,
        channel: context[:channel],
        external_room_id: context[:external_room_id],
        instance_id: context[:instance_id],
        instance_module: context[:instance_module],
        timestamp: timestamp,
        correlation_id: correlation_id
      }
    )
  end

  @doc """
  Emits a `:failed` signal when message delivery has failed.

  ## Metadata
  - `:room_id` - the room ID where delivery was attempted
  - `:reason` - the failure reason
  - `:channel` - the channel module used for delivery attempt
  - `:external_room_id` - the external room identifier
  - `:instance_module` - the messaging module
  - `:instance_id` - the instance ID
  - `:timestamp` - when the event occurred
  - `:correlation_id` - message ID or generated ID for tracing
  """
  @spec emit_failed(String.t(), term(), map()) :: :ok
  def emit_failed(room_id, reason, context) do
    timestamp = DateTime.utc_now()
    correlation_id = context[:message_id] || generate_correlation_id()

    :telemetry.execute(
      [:jido_messaging, :message, :failed],
      %{timestamp: timestamp},
      %{
        room_id: room_id,
        reason: reason,
        channel: context[:channel],
        external_room_id: context[:external_room_id],
        instance_id: context[:instance_id],
        instance_module: context[:instance_module],
        timestamp: timestamp,
        correlation_id: correlation_id
      }
    )
  end

  @doc """
  Generic emit function for room-level events.

  Used by RoomServer to emit signals for various events like:
  - `:presence_changed` - participant presence updated
  - `:typing` - typing indicator changed
  - `:reaction_added` - reaction added to message
  - `:reaction_removed` - reaction removed from message
  - `:message_delivered` - message marked as delivered
  - `:message_read` - message marked as read
  - `:thread_created` - thread created from message
  - `:thread_reply_added` - reply added to thread
  """
  @spec emit(atom(), module(), String.t(), map()) :: :ok
  def emit(event_type, instance_module, room_id, data) do
    timestamp = DateTime.utc_now()
    correlation_id = data[:message_id] || data[:participant_id] || generate_correlation_id()

    event_name = event_name_for(event_type)

    :telemetry.execute(
      event_name,
      %{timestamp: timestamp},
      Map.merge(data, %{
        room_id: room_id,
        instance_module: instance_module,
        timestamp: timestamp,
        correlation_id: correlation_id
      })
    )
  end

  defp event_name_for(:presence_changed), do: [:jido_messaging, :participant, :presence_changed]
  defp event_name_for(:typing), do: [:jido_messaging, :participant, :typing]
  defp event_name_for(:reaction_added), do: [:jido_messaging, :message, :reaction_added]
  defp event_name_for(:reaction_removed), do: [:jido_messaging, :message, :reaction_removed]
  defp event_name_for(:message_delivered), do: [:jido_messaging, :message, :delivered]
  defp event_name_for(:message_read), do: [:jido_messaging, :message, :read]
  defp event_name_for(:thread_created), do: [:jido_messaging, :thread, :created]
  defp event_name_for(:thread_reply_added), do: [:jido_messaging, :thread, :reply_added]
  defp event_name_for(event_type), do: [:jido_messaging, :room, event_type]

  defp generate_correlation_id do
    "corr_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
