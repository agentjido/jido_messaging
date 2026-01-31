defmodule JidoMessaging.Ingest do
  @moduledoc """
  Inbound message processing pipeline.

  Handles incoming messages from channels:
  1. Resolves/creates room by external binding
  2. Resolves/creates participant by external ID
  3. Builds normalized Message struct
  4. Persists message via adapter
  5. Returns message with context for handler processing

  ## Usage

      case Ingest.ingest_incoming(MyApp.Messaging, TelegramChannel, "bot_123", incoming_data) do
        {:ok, message, context} ->
          # message is persisted, context contains room/participant info
        {:error, reason} ->
          # handle error
      end
  """

  require Logger

  alias JidoMessaging.{Message, Content.Text, Signal, RoomServer, RoomSupervisor}

  @type incoming :: JidoMessaging.Channel.incoming_message()
  @type context :: %{
          room: JidoMessaging.Room.t(),
          participant: JidoMessaging.Participant.t(),
          channel: module(),
          instance_id: String.t(),
          external_room_id: term()
        }

  @doc """
  Process an incoming message from a channel.

  Returns `{:ok, message, context}` on success where:
  - `message` is the persisted Message struct
  - `context` contains room, participant, and channel info for reply handling

  Returns `{:ok, :duplicate}` if the message has already been processed.
  """
  @spec ingest_incoming(module(), module(), String.t(), incoming()) ::
          {:ok, Message.t(), context()} | {:ok, :duplicate} | {:error, term()}
  def ingest_incoming(messaging_module, channel_module, instance_id, incoming) do
    channel_type = channel_module.channel_type()
    instance_id = to_string(instance_id)
    external_room_id = incoming.external_room_id

    dedupe_key = build_dedupe_key(channel_type, instance_id, incoming)

    case JidoMessaging.Deduper.check_and_mark(messaging_module, dedupe_key) do
      :duplicate ->
        Logger.debug("[JidoMessaging.Ingest] Duplicate message ignored: #{inspect(dedupe_key)}")
        {:ok, :duplicate}

      :new ->
        do_ingest(messaging_module, channel_module, channel_type, instance_id, external_room_id, incoming)
    end
  end

  @doc """
  Process an incoming message without deduplication check.

  Use this when you've already verified the message is not a duplicate,
  or when deduplication is handled externally.
  """
  @spec ingest_incoming!(module(), module(), String.t(), incoming()) ::
          {:ok, Message.t(), context()} | {:error, term()}
  def ingest_incoming!(messaging_module, channel_module, instance_id, incoming) do
    channel_type = channel_module.channel_type()
    instance_id = to_string(instance_id)
    external_room_id = incoming.external_room_id

    do_ingest(messaging_module, channel_module, channel_type, instance_id, external_room_id, incoming)
  end

  defp do_ingest(messaging_module, channel_module, channel_type, instance_id, external_room_id, incoming) do
    with {:ok, room} <- resolve_room(messaging_module, channel_type, instance_id, incoming),
         {:ok, participant} <- resolve_participant(messaging_module, channel_type, incoming),
         {:ok, message} <- build_and_save_message(messaging_module, room, participant, incoming) do
      context = %{
        room: room,
        participant: participant,
        channel: channel_module,
        instance_id: instance_id,
        external_room_id: external_room_id
      }

      add_to_room_server(messaging_module, room, message, participant)

      Logger.debug("[JidoMessaging.Ingest] Message #{message.id} ingested in room #{room.id}")

      Signal.emit_received(message, context)

      {:ok, message, context}
    end
  end

  defp build_dedupe_key(channel_type, instance_id, incoming) do
    external_message_id = incoming[:external_message_id]
    external_room_id = incoming.external_room_id

    {channel_type, instance_id, external_room_id, external_message_id}
  end

  # Private helpers

  defp resolve_room(messaging_module, channel_type, instance_id, incoming) do
    external_id = to_string(incoming.external_room_id)

    room_attrs = %{
      type: map_chat_type(incoming[:chat_type]),
      name: incoming[:chat_title]
    }

    messaging_module.get_or_create_room_by_external_binding(
      channel_type,
      instance_id,
      external_id,
      room_attrs
    )
  end

  defp resolve_participant(messaging_module, channel_type, incoming) do
    external_id = to_string(incoming.external_user_id)

    participant_attrs = %{
      type: :human,
      identity: %{
        username: incoming[:username],
        display_name: incoming[:display_name]
      }
    }

    messaging_module.get_or_create_participant_by_external_id(
      channel_type,
      external_id,
      participant_attrs
    )
  end

  defp build_and_save_message(messaging_module, room, participant, incoming) do
    content = build_content(incoming)

    message_attrs = %{
      room_id: room.id,
      sender_id: participant.id,
      role: :user,
      content: content,
      status: :sent,
      metadata: build_metadata(incoming)
    }

    messaging_module.save_message(message_attrs)
  end

  defp build_content(%{text: text}) when is_binary(text) and text != "" do
    [%Text{text: text}]
  end

  defp build_content(_), do: []

  defp build_metadata(incoming) do
    %{
      external_message_id: incoming[:external_message_id],
      timestamp: incoming[:timestamp]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp map_chat_type(:private), do: :direct
  defp map_chat_type(:group), do: :group
  defp map_chat_type(:supergroup), do: :group
  defp map_chat_type(:channel), do: :channel
  defp map_chat_type(_), do: :direct

  defp add_to_room_server(messaging_module, room, message, participant) do
    case RoomSupervisor.get_or_start_room(messaging_module, room) do
      {:ok, pid} ->
        RoomServer.add_message(pid, message)
        RoomServer.add_participant(pid, participant)

      {:error, reason} ->
        Logger.warning("[JidoMessaging.Ingest] Failed to start room server: #{inspect(reason)}")
    end
  end
end
