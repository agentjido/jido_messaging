defmodule JidoMessaging.Deliver do
  @moduledoc """
  Outbound message delivery pipeline through `JidoMessaging.OutboundGateway`.

  Handles sending messages to external channels:
  1. Creates assistant message with :sending status
  2. Routes send/edit operations through the outbound gateway
  3. Updates status to :sent or :failed
  4. Returns the persisted message

  ## Usage

      case Deliver.deliver_outgoing(MyApp.Messaging, original_message, "Hello!", context) do
        {:ok, sent_message} ->
          # Message sent and persisted
        {:error, reason} ->
          # Delivery failed
      end
  """

  require Logger

  alias JidoMessaging.{Capabilities, Content.Text, Message, OutboundGateway, RoomServer, Signal}

  @type context :: JidoMessaging.Ingest.context()

  @doc """
  Deliver an outgoing message as a reply.

  Creates an assistant message, sends it via the channel, and updates the message status.
  """
  @spec deliver_outgoing(module(), Message.t(), String.t(), context(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def deliver_outgoing(messaging_module, original_message, text, context, opts \\ []) do
    channel = context.channel
    channel_type = channel.channel_type()
    instance_id = context.instance_id

    content = [%Text{text: text}]
    channel_caps = Capabilities.channel_capabilities(channel)
    filtered_content = filter_and_log_content(content, channel_caps, channel)

    external_reply_to_id = resolve_external_reply_to(messaging_module, original_message, context)

    message_attrs = %{
      room_id: original_message.room_id,
      sender_id: "system",
      role: :assistant,
      content: filtered_content,
      reply_to_id: original_message.id,
      status: :sending,
      metadata: %{channel: channel_type, instance_id: instance_id}
    }

    gateway_opts =
      opts
      |> maybe_put_opt(:reply_to_id, external_reply_to_id)

    with {:ok, message} <- messaging_module.save_message(message_attrs) do
      request_opts = Keyword.put_new(gateway_opts, :idempotency_key, message.id)

      case OutboundGateway.send_message(messaging_module, context, text, request_opts) do
        {:ok, send_result} ->
          external_message_id = send_result.message_id

          updated_message = %{
            message
            | status: :sent,
              external_id: external_message_id,
              metadata:
                message.metadata
                |> Map.put(:external_message_id, external_message_id)
                |> Map.put(:outbound_gateway, gateway_metadata(send_result))
          }

          {:ok, persisted_message} = messaging_module.save_message_struct(updated_message)

          add_to_room_server(messaging_module, original_message.room_id, persisted_message)

          Logger.debug(
            "[JidoMessaging.Deliver] Message #{message.id} sent to room #{original_message.room_id} via partition #{send_result.partition}"
          )

          Signal.emit_sent(persisted_message, context)

          {:ok, persisted_message}

        {:error, outbound_error} ->
          reason = unwrap_gateway_reason(outbound_error)
          failed_message = mark_message_failed(message, outbound_error)
          _ = messaging_module.save_message_struct(failed_message)

          Logger.warning("[JidoMessaging.Deliver] Failed to send message: #{inspect(reason)}")

          Signal.emit_failed(original_message.room_id, reason, context)

          {:error, reason}
      end
    end
  end

  defp resolve_external_reply_to(messaging_module, original_message, _context) do
    case messaging_module.get_message(original_message.id) do
      {:ok, msg} -> msg.external_id
      _ -> nil
    end
  end

  @doc """
  Send a message to a room by room_id (proactive send, not a reply).
  """
  @spec send_to_room(module(), String.t(), String.t(), map(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def send_to_room(messaging_module, room_id, text, channel_context, opts \\ []) do
    channel = channel_context.channel

    content = [%Text{text: text}]
    channel_caps = Capabilities.channel_capabilities(channel)
    filtered_content = filter_and_log_content(content, channel_caps, channel)

    message_attrs = %{
      room_id: room_id,
      sender_id: "system",
      role: :assistant,
      content: filtered_content,
      status: :sending,
      metadata: %{
        channel: channel.channel_type(),
        instance_id: Map.get(channel_context, :instance_id)
      }
    }

    with {:ok, message} <- messaging_module.save_message(message_attrs) do
      request_opts = Keyword.put_new(opts, :idempotency_key, message.id)

      case OutboundGateway.send_message(messaging_module, channel_context, text, request_opts) do
        {:ok, send_result} ->
          updated_message = %{
            message
            | status: :sent,
              external_id: send_result.message_id,
              metadata:
                message.metadata
                |> Map.put(:external_message_id, send_result.message_id)
                |> Map.put(:outbound_gateway, gateway_metadata(send_result))
          }

          {:ok, persisted_message} = messaging_module.save_message_struct(updated_message)
          add_to_room_server(messaging_module, room_id, persisted_message)
          Signal.emit_sent(persisted_message, channel_context)
          {:ok, persisted_message}

        {:error, outbound_error} ->
          reason = unwrap_gateway_reason(outbound_error)
          failed_message = mark_message_failed(message, outbound_error)
          _ = messaging_module.save_message_struct(failed_message)
          Signal.emit_failed(room_id, reason, channel_context)
          {:error, reason}
      end
    end
  end

  @doc """
  Edit a previously-sent message through the outbound gateway.
  """
  @spec edit_outgoing(module(), Message.t(), String.t(), context() | map(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def edit_outgoing(messaging_module, message, text, context, opts \\ [])

  def edit_outgoing(_messaging_module, %Message{external_id: nil}, _text, _context, _opts) do
    {:error, :missing_external_message_id}
  end

  def edit_outgoing(messaging_module, message, text, context, opts) do
    channel = context.channel
    content = [%Text{text: text}]
    channel_caps = Capabilities.channel_capabilities(channel)
    filtered_content = filter_and_log_content(content, channel_caps, channel)

    request_opts = Keyword.put_new(opts, :idempotency_key, "#{message.id}:edit")

    case OutboundGateway.edit_message(
           messaging_module,
           context,
           message.external_id,
           text,
           request_opts
         ) do
      {:ok, edit_result} ->
        updated_message = %{
          message
          | content: filtered_content,
            metadata:
              message.metadata
              |> Map.put(:external_message_id, edit_result.message_id || message.external_id)
              |> Map.put(:outbound_gateway, gateway_metadata(edit_result))
        }

        messaging_module.save_message_struct(updated_message)

      {:error, outbound_error} ->
        {:error, unwrap_gateway_reason(outbound_error)}
    end
  end

  defp add_to_room_server(messaging_module, room_id, message) do
    case RoomServer.whereis(messaging_module, room_id) do
      nil ->
        Logger.debug("[JidoMessaging.Deliver] Room server not running for #{room_id}, skipping")

      pid ->
        RoomServer.add_message(pid, message)
    end
  end

  defp filter_and_log_content(content, channel_caps, channel) do
    unsupported = Capabilities.unsupported_content(content, channel_caps)

    if unsupported != [] do
      unsupported_types = Enum.map(unsupported, fn c -> c.__struct__ end) |> Enum.uniq()

      Logger.warning(
        "[JidoMessaging.Deliver] Channel #{channel.channel_type()} does not support content types: #{inspect(unsupported_types)}. Content will be filtered."
      )
    end

    Capabilities.filter_content(content, channel_caps)
  end

  defp mark_message_failed(message, outbound_error) do
    %{
      message
      | status: :failed,
        metadata:
          message.metadata
          |> maybe_attach_outbound_error(outbound_error)
    }
  end

  defp maybe_attach_outbound_error(metadata, %{type: :outbound_error} = error) do
    Map.put(metadata, :outbound_error, %{
      category: error.category,
      disposition: error.disposition,
      reason: error.reason,
      partition: error.partition
    })
  end

  defp maybe_attach_outbound_error(metadata, _error), do: metadata

  defp gateway_metadata(send_result) do
    %{
      partition: send_result.partition,
      attempts: send_result.attempts,
      operation: send_result.operation,
      pressure_level: send_result.pressure_level,
      idempotent: send_result.idempotent
    }
    |> maybe_put(:security, send_result[:security])
  end

  defp unwrap_gateway_reason(%{type: :outbound_error, reason: reason}), do: reason
  defp unwrap_gateway_reason(reason), do: reason

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
