defmodule JidoMessaging.Demo.Bridge do
  @moduledoc """
  Bridges messages between Telegram and Discord via Signal Bus subscription.

  Subscribes to `jido.messaging.room.message_added` signals and forwards
  to external platforms, skipping the origin platform to prevent loops.

  ## Architecture

  Instead of being called directly by channel handlers, the Bridge now:
  1. Subscribes to the Signal Bus for `message_added` events
  2. Receives signals when any message is added to any room
  3. Forwards to all bound platforms except the origin

  This decouples the Bridge from channel handlers and makes it event-driven.
  """
  use GenServer
  require Logger

  alias JidoMessaging.Channels.{Telegram, Discord}
  alias JidoMessaging.Supervisor, as: MessagingSupervisor

  defstruct [:instance_module, :bindings, :room_id, :subscribed]

  @type binding :: {:telegram | :discord, String.t(), String.t()}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @shared_room_id "demo:lobby"
  @shared_room_name "JidoMessaging Bridge Room"

  @impl true
  def init(opts) do
    instance_module = Keyword.get(opts, :instance_module, JidoMessaging.Demo.Messaging)
    telegram_chat_id = Keyword.fetch!(opts, :telegram_chat_id)
    discord_channel_id = Keyword.fetch!(opts, :discord_channel_id)

    # Bindings: {channel, instance_id, external_id}
    # instance_id must match what the handlers use (full module name as string)
    bindings = [
      {:telegram, to_string(JidoMessaging.Demo.TelegramHandler), to_string(telegram_chat_id)},
      {:discord, to_string(JidoMessaging.Demo.DiscordHandler), to_string(discord_channel_id)}
    ]

    state = %__MODULE__{
      instance_module: instance_module,
      bindings: bindings,
      room_id: @shared_room_id,
      subscribed: false
    }

    # Schedule room setup and subscription
    send(self(), :setup_shared_room)

    Logger.info("[Bridge] Started - TG:#{telegram_chat_id} <-> DC:#{discord_channel_id}")

    {:ok, state}
  end

  @impl true
  def handle_info(:setup_shared_room, state) do
    case setup_shared_room(state) do
      :ok ->
        send(self(), :subscribe)
        {:noreply, state}

      {:error, reason} ->
        Logger.debug("[Bridge] Failed to setup shared room: #{inspect(reason)}, retrying in 100ms")
        Process.send_after(self(), :setup_shared_room, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:subscribe, state) do
    bus_name = MessagingSupervisor.signal_bus_name(state.instance_module)

    case Jido.Signal.Bus.subscribe(bus_name, "jido.messaging.room.message_added") do
      {:ok, _subscription_id} ->
        Logger.info("[Bridge] Subscribed to Signal Bus #{inspect(bus_name)}")
        {:noreply, %{state | subscribed: true}}

      {:error, reason} ->
        Logger.debug("[Bridge] Failed to subscribe to #{inspect(bus_name)}: #{inspect(reason)}, retrying in 100ms")
        Process.send_after(self(), :subscribe, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    handle_signal(signal, state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Signal handling

  defp handle_signal(%{type: "jido.messaging.room.message_added"} = signal, state) do
    message = signal.data.message
    room_id = signal.data.room_id

    # If room_id filter is set, only handle messages for that room
    if state.room_id == nil or room_id == state.room_id do
      origin = get_origin(message)

      # Forward to all bindings except origin
      for binding <- state.bindings, not_origin?(binding, origin) do
        send_to_binding(binding, message)
      end
    end
  end

  defp handle_signal(_signal, _state), do: :ok

  # Shared room setup

  defp setup_shared_room(state) do
    messaging = state.instance_module

    # Create or get the shared room
    case get_or_create_shared_room(messaging) do
      {:ok, room} ->
        # Create bindings for each platform
        Enum.each(state.bindings, fn {channel, instance_id, external_id} ->
          create_binding_if_missing(messaging, room.id, channel, instance_id, external_id)
        end)

        Logger.info("[Bridge] Shared room #{room.id} ready with #{length(state.bindings)} bindings")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_or_create_shared_room(messaging) do
    case messaging.get_room(@shared_room_id) do
      {:ok, room} ->
        {:ok, room}

      {:error, :not_found} ->
        # Create room struct with our fixed ID
        room = %JidoMessaging.Room{
          id: @shared_room_id,
          type: :group,
          name: @shared_room_name,
          external_bindings: %{},
          metadata: %{},
          inserted_at: DateTime.utc_now()
        }

        messaging.save_room(room)
    end
  end

  defp create_binding_if_missing(messaging, room_id, channel, instance_id, external_id) do
    case messaging.get_room_by_external_binding(channel, instance_id, external_id) do
      {:ok, _existing} ->
        Logger.debug("[Bridge] Binding already exists: #{channel}/#{instance_id}/#{external_id}")
        :ok

      {:error, :not_found} ->
        case messaging.create_room_binding(room_id, channel, instance_id, external_id, %{}) do
          {:ok, binding} ->
            Logger.info(
              "[Bridge] Created binding #{binding.id}: #{channel}/#{instance_id}/#{external_id} -> #{room_id}"
            )

            :ok

          {:error, reason} ->
            Logger.warning("[Bridge] Failed to create binding: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # Origin detection from message metadata

  defp get_origin(%{metadata: metadata}) when is_map(metadata) do
    channel = metadata[:channel] || metadata["channel"]
    {channel, nil}
  end

  defp get_origin(_), do: {nil, nil}

  defp not_origin?({channel, _instance, _external_id}, {origin_channel, _}) do
    # Convert both to atoms for comparison
    normalize_channel(channel) != normalize_channel(origin_channel)
  end

  defp normalize_channel(channel) when is_atom(channel), do: channel
  defp normalize_channel("telegram"), do: :telegram
  defp normalize_channel("discord"), do: :discord
  defp normalize_channel(_), do: nil

  # Delivery

  defp send_to_binding({:telegram, _instance, chat_id}, message) do
    text = format_message(message, :telegram)
    Logger.info("[Bridge] -> TG: #{text}")

    try do
      case Telegram.send_message(chat_id, text) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[Bridge] Telegram send failed: #{inspect(reason)}")
      end
    rescue
      e -> Logger.warning("[Bridge] Telegram send crashed: #{inspect(e)}")
    end
  end

  defp send_to_binding({:discord, _instance, channel_id}, message) do
    text = format_message(message, :discord)
    Logger.info("[Bridge] -> DC: #{text}")

    try do
      case Discord.send_message(channel_id, text) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("[Bridge] Discord send failed: #{inspect(reason)}")
      end
    rescue
      e -> Logger.warning("[Bridge] Discord send crashed: #{inspect(e)}")
    end
  end

  defp format_message(message, _target) do
    text = extract_text(message)
    username = get_username(message)
    source = get_source_tag(message)

    "[#{source} #{username}] #{text}"
  end

  defp get_source_tag(%{metadata: %{channel: :telegram}}), do: "TG"
  defp get_source_tag(%{metadata: %{channel: :discord}}), do: "DC"
  defp get_source_tag(%{metadata: %{channel: :agent}}), do: "AG"
  defp get_source_tag(%{metadata: %{"channel" => "telegram"}}), do: "TG"
  defp get_source_tag(%{metadata: %{"channel" => "discord"}}), do: "DC"
  defp get_source_tag(%{metadata: %{"channel" => "agent"}}), do: "AG"
  defp get_source_tag(_), do: "??"

  defp get_username(%{metadata: metadata}) when is_map(metadata) do
    metadata[:username] || metadata["username"] ||
      metadata[:display_name] || metadata["display_name"] ||
      "unknown"
  end

  defp get_username(_), do: "unknown"

  defp extract_text(%{content: [%{text: text} | _]}) when is_binary(text), do: text
  defp extract_text(%{content: [%{"text" => text} | _]}) when is_binary(text), do: text

  defp extract_text(%{content: content}) when is_list(content) do
    Enum.find_value(content, fn
      %{type: :text, text: text} -> text
      %{"type" => "text", "text" => text} -> text
      %{text: text} when is_binary(text) -> text
      %JidoMessaging.Content.Text{text: text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil

  # Legacy API - kept for backwards compatibility during migration
  # These will be removed once Phase 3 is verified working

  @doc deprecated: "Bridge now operates via Signal Bus subscription"
  def forward_from_telegram(_message, _context) do
    Logger.debug("[Bridge] forward_from_telegram called but Bridge is now signal-driven")
    :ok
  end

  @doc deprecated: "Bridge now operates via Signal Bus subscription"
  def forward_from_discord(_message, _context) do
    Logger.debug("[Bridge] forward_from_discord called but Bridge is now signal-driven")
    :ok
  end
end
