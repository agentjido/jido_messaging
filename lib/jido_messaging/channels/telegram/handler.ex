defmodule JidoMessaging.Channels.Telegram.Handler do
  @moduledoc """
  Telegram polling handler using Telegex.Polling.GenHandler.

  This module provides a macro to generate Telegram bot handlers that integrate
  with JidoMessaging's ingest and delivery pipelines.

  ## Usage

  Define a handler module in your application:

      defmodule MyApp.TelegramHandler do
        use JidoMessaging.Channels.Telegram.Handler,
          messaging: MyApp.Messaging,
          on_message: &MyApp.MessageHandler.handle/2
      end

  Add it to your supervision tree:

      children = [
        MyApp.Messaging,
        MyApp.TelegramHandler
      ]

  ## Configuration

  Configure Telegex with your bot token:

      # config/runtime.exs
      config :telegex, token: System.get_env("TELEGRAM_BOT_TOKEN")
      config :telegex, caller_adapter: Telegex.Caller.Adapter.Finch

  ## Options

  - `:messaging` - The JidoMessaging instance module (required)
  - `:on_message` - Callback function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:instance_id` - Custom instance ID (defaults to module name)
  """

  require Logger

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Telegex.Polling.GenHandler

      require Logger

      @messaging_module Keyword.fetch!(opts, :messaging)
      @on_message_callback Keyword.get(opts, :on_message)
      @instance_id Keyword.get(opts, :instance_id, __MODULE__ |> to_string())

      @impl true
      def on_boot do
        case Telegex.get_me() do
          {:ok, bot_user} ->
            Logger.info("[JidoMessaging.Telegram] Bot @#{bot_user.username} connected (polling mode)")

            Telegex.delete_webhook()

          {:error, reason} ->
            Logger.error("[JidoMessaging.Telegram] Failed to connect: #{inspect(reason)}")
        end

        %Telegex.Polling.Config{}
      end

      @impl true
      def on_update(update) do
        JidoMessaging.Channels.Telegram.Handler.process_update(
          update,
          @messaging_module,
          @instance_id,
          @on_message_callback
        )
      end
    end
  end

  @doc false
  def process_update(update, messaging_module, instance_id, on_message_callback) do
    alias JidoMessaging.Channels.Telegram
    alias JidoMessaging.{Ingest, Deliver}

    case Telegram.transform_incoming(update) do
      {:ok, incoming} ->
        case Ingest.ingest_incoming(messaging_module, Telegram, instance_id, incoming) do
          {:ok, message, context} ->
            handle_message_callback(message, context, on_message_callback, messaging_module)

          {:error, reason} ->
            Logger.warning("[JidoMessaging.Telegram] Ingest failed: #{inspect(reason)}")
        end

      {:error, :no_message} ->
        :ok

      {:error, reason} ->
        Logger.debug("[JidoMessaging.Telegram] Skipping update: #{inspect(reason)}")
    end

    :ok
  end

  defp handle_message_callback(message, _context, nil, _messaging_module) do
    Logger.debug("[JidoMessaging.Telegram] Message received (no handler): #{message.id}")
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
        Logger.warning("[JidoMessaging.Telegram] Handler error: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("[JidoMessaging.Telegram] Unexpected handler result: #{inspect(other)}")
        :ok
    end
  end
end
