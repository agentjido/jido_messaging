defmodule JidoMessaging.Channels.Discord.Handler do
  @moduledoc """
  Discord event handler using Nostrum.Consumer.

  This module provides a macro to generate Discord bot handlers that integrate
  with JidoMessaging's ingest and delivery pipelines.

  ## Usage

  Define a handler module in your application:

      defmodule MyApp.DiscordHandler do
        use JidoMessaging.Channels.Discord.Handler,
          messaging: MyApp.Messaging,
          on_message: &MyApp.MessageHandler.handle/2
      end

  Add it to your supervision tree:

      children = [
        MyApp.Messaging,
        MyApp.DiscordHandler
      ]

  ## Configuration

  Nostrum requires configuration in your config.exs:

      # config/config.exs
      config :nostrum,
        token: System.get_env("DISCORD_BOT_TOKEN"),
        gateway_intents: [:guilds, :guild_messages, :message_content, :direct_messages]

  Note: The `message_content` intent is required to read message content and must be
  enabled in your Discord Application settings under "Privileged Gateway Intents".

  ## Options

  - `:messaging` - The JidoMessaging instance module (required)
  - `:on_message` - Callback function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:instance_id` - Custom instance ID (defaults to module name)
  """

  require Logger

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Nostrum.Consumer

      require Logger

      @messaging_module Keyword.fetch!(opts, :messaging)
      @on_message_callback Keyword.get(opts, :on_message)
      @instance_id Keyword.get(opts, :instance_id, __MODULE__ |> to_string())

      @impl Nostrum.Consumer
      def handle_event({:READY, _data, _ws_state}) do
        Logger.info("[JidoMessaging.Discord] Bot connected and ready")
        :ok
      end

      @impl Nostrum.Consumer
      def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
        # Ignore messages from bots (including ourselves)
        unless msg.author.bot do
          JidoMessaging.Channels.Discord.Handler.process_update(
            msg,
            @messaging_module,
            @instance_id,
            @on_message_callback
          )
        end

        :ok
      end

      @impl Nostrum.Consumer
      def handle_event(_event) do
        :ok
      end
    end
  end

  @doc false
  def process_update(msg, messaging_module, instance_id, on_message_callback) do
    alias JidoMessaging.Channels.Discord
    alias JidoMessaging.{Ingest, Deliver}

    case Discord.transform_incoming(msg) do
      {:ok, incoming} ->
        case Ingest.ingest_incoming(messaging_module, Discord, instance_id, incoming) do
          {:ok, message, context} ->
            handle_message_callback(message, context, on_message_callback, messaging_module)

          {:error, reason} ->
            Logger.warning("[JidoMessaging.Discord] Ingest failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("[JidoMessaging.Discord] Skipping message: #{inspect(reason)}")
    end

    :ok
  end

  defp handle_message_callback(message, _context, nil, _messaging_module) do
    Logger.debug("[JidoMessaging.Discord] Message received (no handler): #{message.id}")
    :ok
  end

  defp handle_message_callback(message, context, callback, messaging_module) when is_function(callback, 2) do
    alias JidoMessaging.Deliver

    case callback.(message, context) do
      {:reply, text} when is_binary(text) ->
        Deliver.deliver_outgoing(messaging_module, message, text, context)

      {:reply, text, opts} when is_binary(text) ->
        Deliver.deliver_outgoing(messaging_module, message, text, context, opts)

      :noreply ->
        :ok

      {:error, reason} ->
        Logger.warning("[JidoMessaging.Discord] Handler error: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("[JidoMessaging.Discord] Unexpected handler result: #{inspect(other)}")
        :ok
    end
  end
end
