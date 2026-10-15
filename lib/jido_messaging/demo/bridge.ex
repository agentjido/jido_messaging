defmodule Jido.Messaging.Demo.Bridge do
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

  Forwarding uses the configured `:principal_id` and existing room/bridge grants.
  The host must register both native bindings and grant posting access.
  The bridge does not create grants from observed messages.
  """
  use GenServer
  require Logger

  alias Jido.Messaging.{AuthorizationScope, Events, Message, Runtime, Subscription}
  alias Jido.Messaging.Signal.{Context, Identity, SendMessage}

  @schema Zoi.struct(
            __MODULE__,
            %{
              instance_module: Zoi.module(),
              principal_id: Zoi.string() |> Zoi.nullish(),
              bindings: Zoi.array(Zoi.any()) |> Zoi.default([]),
              room_id: Zoi.string() |> Zoi.nullish(),
              subscribed: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type binding :: {:telegram | :discord, module(), String.t(), String.t()}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @shared_room_id "demo:lobby"
  @shared_room_name "Jido.Messaging Bridge Room"

  @impl true
  def init(opts) do
    instance_module = Keyword.get(opts, :instance_module, Jido.Messaging.Demo.Messaging)
    telegram_chat_id = Keyword.fetch!(opts, :telegram_chat_id)
    discord_channel_id = Keyword.fetch!(opts, :discord_channel_id)

    telegram_adapter =
      resolve_adapter_module(
        opts,
        :telegram_adapter,
        "JIDO_MESSAGING_DEMO_TELEGRAM_ADAPTER"
      )

    discord_adapter =
      resolve_adapter_module(
        opts,
        :discord_adapter,
        "JIDO_MESSAGING_DEMO_DISCORD_ADAPTER"
      )

    telegram_bridge_id = Keyword.get(opts, :telegram_bridge_id, to_string(telegram_adapter))
    discord_bridge_id = Keyword.get(opts, :discord_bridge_id, to_string(discord_adapter))

    # Bindings: {channel, adapter_module, bridge_id, external_id}
    bindings = [
      {:telegram, telegram_adapter, to_string(telegram_bridge_id), to_string(telegram_chat_id)},
      {:discord, discord_adapter, to_string(discord_bridge_id), to_string(discord_channel_id)}
    ]

    state = %__MODULE__{
      instance_module: instance_module,
      principal_id: Keyword.get(opts, :principal_id),
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
    case Subscription.ensure(state.instance_module, self(), "jido.messaging.room.message_added",
           source: Events.source(state.instance_module),
           subject: Identity.room_subject(state.room_id)
         ) do
      {:ok, _worker} ->
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :subscribe, 100)
        {:noreply, state}
    end
  end

  def handle_info({:messaging_subscription_started, worker}, state) do
    Subscription.monitor(worker)
    {:noreply, state}
  end

  def handle_info({:messaging_subscription_status, worker, subscribed}, state) do
    if Subscription.current?(state.instance_module, self(), worker),
      do: {:noreply, %{state | subscribed: subscribed}},
      else: {:noreply, state}
  end

  def handle_info({:messaging_subscription_down, _ref, :process, _worker, _reason}, state) do
    send(self(), :subscribe)
    {:noreply, %{state | subscribed: false}}
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

  defp handle_signal(%Jido.Signal{type: "jido.messaging.room.message_added"} = signal, state) do
    with {:ok, catalog} <- Runtime.catalog(state.instance_module.__jido_messaging__(:runtime)),
         {:ok, ^signal} <- signal |> Jido.Signal.to_map() |> Jido.Signal.from_map(),
         {:ok, ^signal} <- Jido.Signal.Catalog.validate(catalog, signal),
         {:ok, ^signal} <- Jido.Chat.Signal.Policy.validate(signal),
         true <- signal.source == Events.source(state.instance_module),
         true <- signal.subject == Identity.room_subject(state.room_id),
         true <- signal.data["room_id"] == state.room_id,
         {:ok, %Message{room_id: room_id} = message} <- state.instance_module.get_message(signal.data["message_id"]),
         true <- room_id == state.room_id do
      origin = get_origin(message)

      # Forward to all bindings except origin
      for binding <- state.bindings, not_origin?(binding, origin) do
        send_to_binding(binding, message, signal, state)
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp handle_signal(_signal, _state), do: :ok

  # Shared room setup

  defp setup_shared_room(state) do
    messaging = state.instance_module

    with :ok <- validate_binding_owners(messaging, state.bindings),
         {:ok, room} <- get_or_create_shared_room(messaging),
         :ok <- create_bindings(messaging, room.id, state.bindings) do
      Logger.info("[Bridge] Shared room #{room.id} ready with #{length(state.bindings)} bindings")
      :ok
    end
  rescue
    _ -> {:error, :setup_failed}
  catch
    _, _ -> {:error, :setup_failed}
  end

  defp validate_binding_owners(messaging, bindings) do
    Enum.reduce_while(bindings, :ok, fn {channel, _adapter, bridge, external}, :ok ->
      case messaging.get_room_by_external_binding(channel, bridge, external) do
        {:ok, %{id: @shared_room_id}} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:ok, %{id: owner}} -> {:halt, {:error, {:room_binding_scope_conflict, owner, @shared_room_id}}}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :setup_failed}}
      end
    end)
  end

  defp create_bindings(messaging, room_id, bindings) do
    Enum.reduce_while(bindings, :ok, fn {channel, _adapter, bridge, external}, :ok ->
      case create_binding_if_missing(messaging, room_id, channel, bridge, external) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp get_or_create_shared_room(messaging) do
    case messaging.get_room(@shared_room_id) do
      {:ok, room} ->
        {:ok, room}

      {:error, :not_found} ->
        # Create room struct with our fixed ID
        room = %Jido.Chat.Room{
          id: @shared_room_id,
          type: :group,
          name: @shared_room_name,
          external_bindings: %{},
          metadata: %{},
          inserted_at: DateTime.utc_now()
        }

        messaging.save_room(room)

      {:error, _} = error ->
        error
    end
  end

  defp create_binding_if_missing(messaging, room_id, channel, bridge_id, external_id) do
    case messaging.get_room_by_external_binding(channel, bridge_id, external_id) do
      {:ok, %{id: ^room_id}} ->
        Logger.debug("[Bridge] Binding already exists: #{channel}/#{bridge_id}/#{external_id}")
        :ok

      {:error, :not_found} ->
        case messaging.create_room_binding(room_id, channel, bridge_id, external_id, %{
               direction: :both,
               enabled: true
             }) do
          {:ok, binding} ->
            Logger.info("[Bridge] Created binding #{binding.id}: #{channel}/#{bridge_id}/#{external_id} -> #{room_id}")

            :ok

          {:error, reason} ->
            Logger.warning("[Bridge] Failed to create binding: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, %{id: owner}} ->
        {:error, {:room_binding_scope_conflict, owner, room_id}}

      {:error, _} = error ->
        error
    end
  end

  # Origin detection from message metadata

  defp get_origin(%{metadata: metadata}) when is_map(metadata) do
    channel = metadata[:channel] || metadata["channel"]
    {channel, nil}
  end

  defp get_origin(_), do: {nil, nil}

  defp not_origin?({channel, _adapter, _bridge_id, _external_id}, {origin_channel, _}) do
    # Convert both to atoms for comparison
    normalize_channel(channel) != normalize_channel(origin_channel)
  end

  defp normalize_channel(channel) when is_atom(channel), do: channel
  defp normalize_channel("telegram"), do: :telegram
  defp normalize_channel("discord"), do: :discord
  defp normalize_channel(_), do: nil

  # Delivery

  defp send_to_binding({channel, adapter, bridge_id, _external_id}, message, parent, state) do
    runtime = state.instance_module.__jido_messaging__(:runtime)

    with {:ok, %Jido.Chat.Binding{adapter: ^adapter}} <- Runtime.binding(runtime, bridge_id),
         {:ok, request} <-
           SendMessage.new(
             %{
               "request_id" => "demo-forward:" <> message.id <> ":" <> bridge_id,
               "room_id" => state.room_id,
               "bridge_id" => bridge_id,
               "text" => format_message(message, channel)
             },
             source: Events.source(state.instance_module),
             subject: Identity.room_subject(state.room_id)
           ),
         {:ok, request} <- Context.attach(request, parent_signal: parent) do
      scope = AuthorizationScope.new(%{kind: :room, room_id: state.room_id, bridge_id: bridge_id})
      state.instance_module.execute(request, principal_id: state.principal_id, authorization_scope: scope)
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
      %Jido.Chat.Content.Text{text: text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil

  defp resolve_adapter_module(opts, opt_key, env_key) do
    module =
      Keyword.get(opts, opt_key) ||
        Application.get_env(:jido_messaging, opt_key) ||
        System.get_env(env_key)

    normalize_module(module)
  end

  defp normalize_module(nil),
    do: raise(ArgumentError, "missing adapter module configuration (set opts or env)")

  defp normalize_module(module) when is_atom(module), do: module

  defp normalize_module(module_name) when is_binary(module_name) and module_name != "" do
    module_name
    |> String.split(".")
    |> Module.concat()
  end

  defp normalize_module(other),
    do: raise(ArgumentError, "invalid adapter module configuration: #{inspect(other)}")
end
