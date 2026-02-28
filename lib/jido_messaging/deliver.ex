defmodule Jido.Messaging.Deliver do
  @moduledoc """
  Outbound message delivery pipeline through `Jido.Messaging.OutboundGateway`.

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

  alias Jido.Chat.{Capabilities, LegacyMessage}
  alias Jido.Chat.Content.Text
  alias Jido.Messaging.{MediaPolicy, OutboundGateway, OutboundRouter, RoomServer, Signal}

  @type context :: Jido.Messaging.Ingest.context()

  @doc """
  Deliver an outgoing message as a reply.

  Creates an assistant message, sends it via the channel, and updates the message status.
  """
  @spec deliver_outgoing(module(), LegacyMessage.t(), String.t(), context(), keyword()) ::
          {:ok, LegacyMessage.t()} | {:error, term()}
  def deliver_outgoing(messaging_module, original_message, text, context, opts \\ []) do
    channel = context.channel
    channel_type = Jido.Messaging.AdapterBridge.channel_type(channel)
    bridge_id = context.bridge_id

    content = [%Text{text: text}]
    channel_caps = Jido.Messaging.AdapterBridge.capabilities(channel)
    filtered_content = filter_and_log_content(content, channel_caps, channel)

    external_reply_to_id = resolve_external_reply_to(messaging_module, original_message, context)

    message_attrs = %{
      room_id: original_message.room_id,
      sender_id: "system",
      role: :assistant,
      content: filtered_content,
      reply_to_id: original_message.id,
      status: :sending,
      metadata: %{channel: channel_type, bridge_id: bridge_id}
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
            "[Jido.Messaging.Deliver] Message #{message.id} sent to room #{original_message.room_id} via partition #{send_result.partition}"
          )

          Signal.emit_sent(persisted_message, context)

          {:ok, persisted_message}

        {:error, outbound_error} ->
          reason = unwrap_gateway_reason(outbound_error)
          failed_message = mark_message_failed(message, outbound_error)
          _ = messaging_module.save_message_struct(failed_message)

          Logger.warning("[Jido.Messaging.Deliver] Failed to send message: #{inspect(reason)}")

          Signal.emit_failed(original_message.room_id, reason, context)

          {:error, reason}
      end
    end
  end

  @doc """
  Deliver an outgoing media payload as a reply.
  """
  @spec deliver_media_outgoing(module(), LegacyMessage.t(), map(), context(), keyword()) ::
          {:ok, LegacyMessage.t()} | {:error, term()}
  def deliver_media_outgoing(messaging_module, original_message, media_payload, context, opts \\ [])
      when is_map(media_payload) do
    channel = context.channel
    channel_type = Jido.Messaging.AdapterBridge.channel_type(channel)
    bridge_id = context.bridge_id
    external_reply_to_id = resolve_external_reply_to(messaging_module, original_message, context)

    with {:ok, media_content, media_metadata} <- normalize_media_content(media_payload, opts),
         {:ok, message} <-
           messaging_module.save_message(%{
             room_id: original_message.room_id,
             sender_id: "system",
             role: :assistant,
             content: media_content,
             reply_to_id: original_message.id,
             status: :sending,
             metadata: %{
               channel: channel_type,
               bridge_id: bridge_id,
               media: media_metadata
             }
           }) do
      request_opts =
        opts
        |> maybe_put_opt(:reply_to_id, external_reply_to_id)
        |> Keyword.put_new(:idempotency_key, message.id)

      case OutboundGateway.send_media(messaging_module, context, media_payload, request_opts) do
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
          Signal.emit_sent(persisted_message, context)
          {:ok, persisted_message}

        {:error, outbound_error} ->
          reason = unwrap_gateway_reason(outbound_error)
          failed_message = mark_message_failed(message, outbound_error)
          _ = messaging_module.save_message_struct(failed_message)
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
  Send a proactive message to a room using bridge-configured routing.
  """
  @spec send_to_room(module(), String.t(), String.t(), keyword()) ::
          {:ok, LegacyMessage.t()} | {:error, term()}
  def send_to_room(messaging_module, room_id, text, opts \\ [])
      when is_atom(messaging_module) and is_binary(room_id) and is_binary(text) and is_list(opts) do
    send_to_room_via_routes(messaging_module, room_id, text, opts)
  end

  @doc """
  Send a proactive message using control-plane routing.

  This path resolves routes via `RoomBinding + BridgeConfig + RoutingPolicy`
  and dispatches through `Jido.Messaging.OutboundRouter`.
  """
  @spec send_to_room_via_routes(module(), String.t(), String.t(), keyword()) ::
          {:ok, LegacyMessage.t()} | {:error, term()}
  def send_to_room_via_routes(messaging_module, room_id, text, opts \\ [])
      when is_atom(messaging_module) and is_binary(room_id) and is_binary(text) and is_list(opts) do
    message_attrs = %{
      room_id: room_id,
      sender_id: "system",
      role: :assistant,
      content: [%Text{text: text}],
      status: :sending,
      metadata: %{delivery: :outbound_router}
    }

    with {:ok, message} <- messaging_module.save_message(message_attrs) do
      route_opts =
        Keyword.update(opts, :gateway_opts, [idempotency_key: message.id], fn gateway_opts ->
          Keyword.put_new(gateway_opts, :idempotency_key, message.id)
        end)

      case OutboundRouter.route_outbound(messaging_module, room_id, text, route_opts) do
        {:ok, summary} ->
          first_delivery = List.first(summary.delivered)
          external_message_id = first_delivery && first_delivery.result.message_id

          updated_message = %{
            message
            | status: :sent,
              external_id: external_message_id,
              metadata:
                message.metadata
                |> maybe_put(:external_message_id, external_message_id)
                |> Map.put(:outbound_router, summarize_outbound_router(summary))
          }

          {:ok, persisted_message} = messaging_module.save_message_struct(updated_message)
          add_to_room_server(messaging_module, room_id, persisted_message)
          Signal.emit_sent(persisted_message, %{room_id: room_id, instance_module: messaging_module})
          {:ok, persisted_message}

        {:error, :no_routes} = error ->
          failed_message = mark_message_failed(message, :no_routes)
          _ = messaging_module.save_message_struct(failed_message)
          error

        {:error, {:delivery_failed, summary}} ->
          failed_message = mark_message_failed(message, {:delivery_failed, summarize_outbound_router(summary)})
          _ = messaging_module.save_message_struct(failed_message)
          {:error, :delivery_failed}

        {:error, reason} ->
          failed_message = mark_message_failed(message, reason)
          _ = messaging_module.save_message_struct(failed_message)
          {:error, reason}
      end
    end
  end

  @doc """
  Edit a previously-sent message through the outbound gateway.
  """
  @spec edit_outgoing(module(), LegacyMessage.t(), String.t(), context() | map(), keyword()) ::
          {:ok, LegacyMessage.t()} | {:error, term()}
  def edit_outgoing(messaging_module, message, text, context, opts \\ [])

  def edit_outgoing(_messaging_module, %LegacyMessage{external_id: nil}, _text, _context, _opts) do
    {:error, :missing_external_message_id}
  end

  def edit_outgoing(messaging_module, message, text, context, opts) do
    channel = context.channel
    content = [%Text{text: text}]
    channel_caps = Jido.Messaging.AdapterBridge.capabilities(channel)
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

  @doc """
  Edit a previously-sent media message through the outbound gateway.
  """
  @spec edit_outgoing_media(module(), LegacyMessage.t(), map(), context() | map(), keyword()) ::
          {:ok, LegacyMessage.t()} | {:error, term()}
  def edit_outgoing_media(messaging_module, message, media_payload, context, opts \\ [])

  def edit_outgoing_media(_messaging_module, %LegacyMessage{external_id: nil}, _media_payload, _context, _opts) do
    {:error, :missing_external_message_id}
  end

  def edit_outgoing_media(messaging_module, message, media_payload, context, opts)
      when is_map(media_payload) do
    request_opts = Keyword.put_new(opts, :idempotency_key, "#{message.id}:edit_media")

    with {:ok, media_content, media_metadata} <- normalize_media_content(media_payload, opts) do
      case OutboundGateway.edit_media(
             messaging_module,
             context,
             message.external_id,
             media_payload,
             request_opts
           ) do
        {:ok, edit_result} ->
          updated_message = %{
            message
            | content: media_content,
              metadata:
                message.metadata
                |> Map.put(:media, media_metadata)
                |> Map.put(:external_message_id, edit_result.message_id || message.external_id)
                |> Map.put(:outbound_gateway, gateway_metadata(edit_result))
          }

          messaging_module.save_message_struct(updated_message)

        {:error, outbound_error} ->
          {:error, unwrap_gateway_reason(outbound_error)}
      end
    end
  end

  defp add_to_room_server(messaging_module, room_id, message) do
    case RoomServer.whereis(messaging_module, room_id) do
      nil ->
        Logger.debug("[Jido.Messaging.Deliver] Room server not running for #{room_id}, skipping")

      pid ->
        RoomServer.add_message(pid, message)
    end
  end

  defp filter_and_log_content(content, channel_caps, channel) do
    unsupported = Capabilities.unsupported_content(content, channel_caps)

    if unsupported != [] do
      unsupported_types = Enum.map(unsupported, fn c -> c.__struct__ end) |> Enum.uniq()

      Logger.warning(
        "[Jido.Messaging.Deliver] Channel #{Jido.Messaging.AdapterBridge.channel_type(channel)} does not support content types: #{inspect(unsupported_types)}. Content will be filtered."
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

  defp maybe_attach_outbound_error(metadata, reason) do
    Map.put(metadata, :outbound_error, %{reason: reason})
  end

  defp gateway_metadata(send_result) do
    %{
      partition: send_result.partition,
      attempts: send_result.attempts,
      operation: send_result.operation,
      pressure_level: send_result.pressure_level,
      idempotent: send_result.idempotent
    }
    |> maybe_put(:route_resolution, send_result[:route_resolution])
    |> maybe_put(:security, send_result[:security])
    |> maybe_put(:media, send_result[:media])
  end

  defp summarize_outbound_router(summary) do
    %{
      attempted: summary.attempted,
      delivered: length(summary.delivered),
      failed: length(summary.failed),
      delivery_mode: summary.policy.delivery_mode,
      failover_policy: summary.policy.failover_policy,
      routes:
        Enum.map(summary.delivered, fn %{route: route} ->
          %{bridge_id: route.bridge_id, channel: route.channel, external_room_id: route.external_room_id}
        end)
    }
  end

  defp normalize_media_content(media_payload, opts) do
    media_opts = media_policy_opts(opts)

    case MediaPolicy.normalize_inbound([media_payload], media_opts) do
      {:ok, media_content, media_metadata} ->
        {:ok, media_content, media_metadata}

      {:error, reason, _metadata} ->
        {:error, reason}
    end
  end

  defp media_policy_opts(opts) do
    case Keyword.get(opts, :media_policy, []) do
      value when is_list(value) -> value
      value when is_map(value) -> Map.to_list(value)
      _ -> []
    end
  end

  defp unwrap_gateway_reason(%{type: :outbound_error, reason: reason}), do: reason

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
