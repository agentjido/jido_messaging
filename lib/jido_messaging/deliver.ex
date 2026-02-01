defmodule JidoMessaging.Deliver do
  @moduledoc """
  Outbound message delivery pipeline.

  Handles sending messages to external channels:
  1. Creates assistant message with :sending status
  2. Calls channel.send_message
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

  alias JidoMessaging.{Message, Content.Text, Signal, RoomServer, Capabilities}

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
    external_room_id = context.external_room_id
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

    opts = if external_reply_to_id, do: Keyword.put(opts, :reply_to_id, external_reply_to_id), else: opts

    with {:ok, message} <- messaging_module.save_message(message_attrs),
         {:ok, send_result} <- channel.send_message(external_room_id, text, opts) do
      external_message_id = send_result[:message_id]

      updated_message = %{
        message
        | status: :sent,
          external_id: external_message_id,
          metadata:
            Map.merge(message.metadata, %{
              external_message_id: external_message_id
            })
      }

      {:ok, persisted_message} = messaging_module.save_message_struct(updated_message)

      add_to_room_server(messaging_module, original_message.room_id, persisted_message)

      Logger.debug("[JidoMessaging.Deliver] Message #{message.id} sent to room #{original_message.room_id}")

      Signal.emit_sent(persisted_message, context)

      {:ok, persisted_message}
    else
      {:error, reason} = error ->
        Logger.warning("[JidoMessaging.Deliver] Failed to send message: #{inspect(reason)}")

        Signal.emit_failed(original_message.room_id, reason, context)

        error
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
    external_room_id = channel_context.external_room_id

    content = [%Text{text: text}]
    channel_caps = Capabilities.channel_capabilities(channel)
    filtered_content = filter_and_log_content(content, channel_caps, channel)

    message_attrs = %{
      room_id: room_id,
      sender_id: "system",
      role: :assistant,
      content: filtered_content,
      status: :sending,
      metadata: %{}
    }

    with {:ok, message} <- messaging_module.save_message(message_attrs),
         {:ok, send_result} <- channel.send_message(external_room_id, text, opts) do
      updated_message = %{
        message
        | status: :sent,
          metadata:
            Map.merge(message.metadata, %{
              external_message_id: send_result[:message_id]
            })
      }

      Signal.emit_sent(updated_message, channel_context)

      {:ok, updated_message}
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
end
