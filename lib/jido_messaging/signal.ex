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
  """

  @doc """
  Emits a `:received` signal when a message has been ingested.

  ## Metadata
  - `:message` - the ingested `JidoMessaging.Message` struct
  - `:room_id` - the room ID where the message was received
  - `:participant_id` - the sender's participant ID
  - `:channel` - the channel module that received the message
  - `:instance_id` - the instance ID of the channel
  """
  @spec emit_received(JidoMessaging.Message.t(), map()) :: :ok
  def emit_received(message, context) do
    :telemetry.execute(
      [:jido_messaging, :message, :received],
      %{timestamp: DateTime.utc_now()},
      %{
        message: message,
        room_id: message.room_id,
        participant_id: message.sender_id,
        channel: context[:channel],
        instance_id: context[:instance_id]
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
  """
  @spec emit_sent(JidoMessaging.Message.t(), map()) :: :ok
  def emit_sent(message, context) do
    :telemetry.execute(
      [:jido_messaging, :message, :sent],
      %{timestamp: DateTime.utc_now()},
      %{
        message: message,
        room_id: message.room_id,
        channel: context[:channel],
        external_room_id: context[:external_room_id]
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
  """
  @spec emit_failed(String.t(), term(), map()) :: :ok
  def emit_failed(room_id, reason, context) do
    :telemetry.execute(
      [:jido_messaging, :message, :failed],
      %{timestamp: DateTime.utc_now()},
      %{
        room_id: room_id,
        reason: reason,
        channel: context[:channel],
        external_room_id: context[:external_room_id]
      }
    )
  end
end
