defmodule Jido.Messaging.Signal do
  @moduledoc """
  Signal emission for messaging events using dual-emission pattern.

  Emits both:
  - `:telemetry` events for metrics and instrumentation
  - `Jido.Signal` CloudEvents for domain events with causality tracking

  ## Telemetry Events

  - `[:jido_messaging, :message, :received]` - when a message is ingested
  - `[:jido_messaging, :message, :sent]` - when a message is delivered successfully
  - `[:jido_messaging, :message, :failed]` - when delivery fails

  ## Jido.Signal CloudEvents

  - `jido.messaging.message.received` - message ingested
  - `jido.messaging.message.sent` - message delivered
  - `jido.messaging.message.failed` - delivery failed
  - `jido.messaging.agent.triggered` - agent trigger detected
  - `jido.messaging.agent.started` - agent execution started
  - `jido.messaging.agent.completed` - agent execution completed
  - `jido.messaging.agent.failed` - agent execution failed
  - `jido.messaging.instance.*` - instance lifecycle events

  ## Usage

  To attach a telemetry handler:

      :telemetry.attach(
        "my-handler",
        [:jido_messaging, :message, :received],
        &MyHandler.handle_event/4,
        nil
      )

  To subscribe to Jido.Signal events:

      Jido.Signal.Bus.subscribe(MyApp.Messaging.SignalBus, "jido.messaging.message.*")

  ## Standard Metadata Keys

  All signals include a consistent set of metadata keys for correlation and tracing.
  See `@metadata_keys` for the standard keys included in all events.
  """

  require Logger

  alias Jido.Messaging.Supervisor, as: MessagingSupervisor

  @metadata_keys [
    :instance_module,
    :room_id,
    :bridge_id,
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
  - `:message` - the ingested `Jido.Chat.LegacyMessage` struct
  - `:room_id` - the room ID where the message was received
  - `:participant_id` - the sender's participant ID
  - `:channel` - the channel module that received the message
  - `:bridge_id` - the bridge ID of the channel
  - `:instance_module` - the messaging module
  - `:timestamp` - when the event occurred
  - `:correlation_id` - message ID or generated ID for tracing
  """
  @spec emit_received(Jido.Chat.LegacyMessage.t(), map()) :: :ok
  def emit_received(message, context) do
    timestamp = DateTime.utc_now()
    correlation_id = message.id || generate_correlation_id()

    metadata = %{
      message: message,
      room_id: message.room_id,
      participant_id: message.sender_id,
      channel: context[:channel],
      bridge_id: context[:bridge_id],
      instance_module: context[:instance_module],
      timestamp: timestamp,
      correlation_id: correlation_id
    }

    emit_telemetry([:jido_messaging, :message, :received], %{timestamp: timestamp}, metadata)

    emit_jido_signal(
      "jido.messaging.message.received",
      message_to_data(message, metadata),
      context[:instance_module],
      message.room_id,
      correlation_id: correlation_id
    )
  end

  @doc """
  Emits a `:sent` signal when a message has been delivered successfully.

  ## Metadata
  - `:message` - the sent `Jido.Chat.LegacyMessage` struct
  - `:room_id` - the room ID where the message was sent
  - `:channel` - the channel module used for delivery
  - `:external_room_id` - the external room identifier
  - `:instance_module` - the messaging module
  - `:bridge_id` - the bridge ID
  - `:timestamp` - when the event occurred
  - `:correlation_id` - message ID or generated ID for tracing
  """
  @spec emit_sent(Jido.Chat.LegacyMessage.t(), map()) :: :ok
  def emit_sent(message, context) do
    timestamp = DateTime.utc_now()
    correlation_id = message.id || generate_correlation_id()

    metadata = %{
      message: message,
      room_id: message.room_id,
      channel: context[:channel],
      external_room_id: context[:external_room_id],
      bridge_id: context[:bridge_id],
      instance_module: context[:instance_module],
      timestamp: timestamp,
      correlation_id: correlation_id
    }

    emit_telemetry([:jido_messaging, :message, :sent], %{timestamp: timestamp}, metadata)

    emit_jido_signal(
      "jido.messaging.message.sent",
      message_to_data(message, metadata),
      context[:instance_module],
      message.room_id,
      correlation_id: correlation_id
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
  - `:bridge_id` - the bridge ID
  - `:timestamp` - when the event occurred
  - `:correlation_id` - message ID or generated ID for tracing
  """
  @spec emit_failed(String.t(), term(), map()) :: :ok
  def emit_failed(room_id, reason, context) do
    timestamp = DateTime.utc_now()
    correlation_id = context[:message_id] || generate_correlation_id()

    metadata = %{
      room_id: room_id,
      reason: reason,
      channel: context[:channel],
      external_room_id: context[:external_room_id],
      bridge_id: context[:bridge_id],
      instance_module: context[:instance_module],
      timestamp: timestamp,
      correlation_id: correlation_id
    }

    emit_telemetry([:jido_messaging, :message, :failed], %{timestamp: timestamp}, metadata)

    emit_jido_signal(
      "jido.messaging.message.failed",
      %{
        room_id: room_id,
        reason: inspect(reason),
        channel: channel_name(context[:channel]),
        external_room_id: context[:external_room_id],
        bridge_id: context[:bridge_id]
      },
      context[:instance_module],
      room_id,
      correlation_id: correlation_id
    )
  end

  @doc """
  Emits an agent lifecycle signal.

  ## Events
  - `:triggered` - agent trigger condition matched
  - `:started` - agent execution began
  - `:completed` - agent execution finished successfully
  - `:failed` - agent execution failed
  """
  @spec emit_agent(atom(), module(), String.t(), String.t(), map()) :: :ok
  def emit_agent(event_type, instance_module, room_id, agent_id, data \\ %{}) do
    timestamp = DateTime.utc_now()
    correlation_id = data[:message_id] || generate_correlation_id()

    metadata =
      Map.merge(data, %{
        room_id: room_id,
        agent_id: agent_id,
        instance_module: instance_module,
        timestamp: timestamp,
        correlation_id: correlation_id
      })

    telemetry_event = [:jido_messaging, :agent, event_type]
    emit_telemetry(telemetry_event, %{timestamp: timestamp}, metadata)

    signal_type = "jido.messaging.agent.#{event_type}"

    emit_jido_signal(
      signal_type,
      Map.merge(data, %{agent_id: agent_id, room_id: room_id}),
      instance_module,
      room_id,
      correlation_id: correlation_id,
      causation_id: data[:causation_id]
    )
  end

  @doc """
  Emits an instance lifecycle signal.

  ## Events
  - `:started` - instance started
  - `:connecting` - instance connecting to external service
  - `:connected` - instance connected
  - `:disconnected` - instance disconnected
  - `:stopped` - instance stopped
  - `:error` - instance error
  """
  @spec emit_instance(atom(), module(), String.t(), map()) :: :ok
  def emit_instance(event_type, instance_module, instance_id, data \\ %{}) do
    timestamp = DateTime.utc_now()
    correlation_id = data[:correlation_id] || generate_correlation_id()

    metadata =
      Map.merge(data, %{
        instance_id: instance_id,
        instance_module: instance_module,
        timestamp: timestamp,
        correlation_id: correlation_id
      })

    telemetry_event = [:jido_messaging, :instance, event_type]
    emit_telemetry(telemetry_event, %{timestamp: timestamp}, metadata)

    signal_type = "jido.messaging.instance.#{event_type}"

    emit_jido_signal(
      signal_type,
      Map.merge(data, %{instance_id: instance_id}),
      instance_module,
      nil,
      correlation_id: correlation_id
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

    metadata =
      Map.merge(data, %{
        room_id: room_id,
        instance_module: instance_module,
        timestamp: timestamp,
        correlation_id: correlation_id
      })

    emit_telemetry(event_name, %{timestamp: timestamp}, metadata)

    signal_type = signal_type_for(event_type)

    emit_jido_signal(
      signal_type,
      Map.merge(data, %{room_id: room_id}),
      instance_module,
      room_id,
      correlation_id: correlation_id
    )
  end

  defp event_name_for(:message_added), do: [:jido_messaging, :room, :message_added]
  defp event_name_for(:participant_joined), do: [:jido_messaging, :room, :participant_joined]
  defp event_name_for(:participant_left), do: [:jido_messaging, :room, :participant_left]
  defp event_name_for(:presence_changed), do: [:jido_messaging, :participant, :presence_changed]
  defp event_name_for(:typing), do: [:jido_messaging, :participant, :typing]
  defp event_name_for(:reaction_added), do: [:jido_messaging, :message, :reaction_added]
  defp event_name_for(:reaction_removed), do: [:jido_messaging, :message, :reaction_removed]
  defp event_name_for(:message_delivered), do: [:jido_messaging, :message, :delivered]
  defp event_name_for(:message_read), do: [:jido_messaging, :message, :read]
  defp event_name_for(:thread_created), do: [:jido_messaging, :thread, :created]
  defp event_name_for(:thread_reply_added), do: [:jido_messaging, :thread, :reply_added]
  defp event_name_for(event_type), do: [:jido_messaging, :room, event_type]

  defp signal_type_for(:message_added), do: "jido.messaging.room.message_added"
  defp signal_type_for(:participant_joined), do: "jido.messaging.room.participant_joined"
  defp signal_type_for(:participant_left), do: "jido.messaging.room.participant_left"
  defp signal_type_for(:presence_changed), do: "jido.messaging.participant.presence_changed"
  defp signal_type_for(:typing), do: "jido.messaging.participant.typing"
  defp signal_type_for(:reaction_added), do: "jido.messaging.message.reaction_added"
  defp signal_type_for(:reaction_removed), do: "jido.messaging.message.reaction_removed"
  defp signal_type_for(:message_delivered), do: "jido.messaging.message.delivered"
  defp signal_type_for(:message_read), do: "jido.messaging.message.read"
  defp signal_type_for(:thread_created), do: "jido.messaging.thread.created"
  defp signal_type_for(:thread_reply_added), do: "jido.messaging.thread.reply_added"
  defp signal_type_for(event_type), do: "jido.messaging.room.#{event_type}"

  defp emit_telemetry(event_name, measurements, metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  defp emit_jido_signal(type, data, instance_module, subject, opts) do
    bus_name = MessagingSupervisor.signal_bus_name(instance_module)

    # Note: Signal Bus doesn't register with Process.whereis - just try to publish
    if instance_module do
      source = build_source(instance_module, opts[:bridge_id] || opts[:instance_id])

      signal_opts =
        %{
          source: source,
          subject: subject
        }
        |> maybe_put_correlationid(opts[:correlation_id])
        |> maybe_put_extension(:causation_id, opts[:causation_id])

      case Jido.Signal.new(type, data, signal_opts) do
        {:ok, signal} ->
          # Log correlation info for debugging
          corr_id = get_in(signal.extensions, ["correlationid", :id])
          Logger.debug("[signal] type=#{type} correlation_id=#{corr_id || "none"}")

          case Jido.Signal.Bus.publish(bus_name, [signal]) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.debug("[Jido.Messaging.Signal] Failed to publish signal #{type}: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[Jido.Messaging.Signal] Failed to create signal #{type}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp build_source(instance_module, instance_id) do
    base = "jido_messaging/#{inspect(instance_module)}"
    if instance_id, do: "#{base}/#{instance_id}", else: base
  end

  defp maybe_put_extension(opts, _key, nil), do: opts
  defp maybe_put_extension(opts, key, value), do: Map.put(opts, key, value)

  defp maybe_put_correlationid(opts, nil), do: opts

  defp maybe_put_correlationid(opts, correlation_id) do
    Map.put(opts, :correlationid, %{id: correlation_id})
  end

  defp message_to_data(message, metadata) do
    %{
      message_id: message.id,
      room_id: message.room_id,
      sender_id: message.sender_id,
      role: message.role,
      status: message.status,
      channel: channel_name(metadata[:channel]),
      bridge_id: metadata[:bridge_id],
      external_room_id: metadata[:external_room_id]
    }
  end

  defp channel_name(nil), do: nil
  defp channel_name(module) when is_atom(module), do: to_string(module)
  defp channel_name(other), do: inspect(other)

  defp generate_correlation_id do
    "corr_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
