defmodule JidoMessaging.Channels.Slack.Handler do
  @moduledoc """
  Slack event handler using Slack.Bot behaviour.

  This module provides a macro to generate Slack bot handlers that integrate
  with JidoMessaging's ingest and delivery pipelines.

  ## Usage

  Define a handler module in your application:

      defmodule MyApp.SlackHandler do
        use JidoMessaging.Channels.Slack.Handler,
          messaging: MyApp.Messaging,
          on_message: &MyApp.MessageHandler.handle/2
      end

  Start the Slack socket connection in your supervision tree:

      children = [
        MyApp.Messaging,
        {Slack.Supervisor, bot: MyApp.SlackHandler, token: bot_token, app_token: app_token}
      ]

  ## Configuration

  Slack requires both a Bot Token and an App Token for Socket Mode:

      # config/runtime.exs
      config :slack_elixir,
        token: System.get_env("SLACK_BOT_TOKEN"),
        app_token: System.get_env("SLACK_APP_TOKEN")

  To get these tokens:
  1. Go to https://api.slack.com/apps and create/select your app
  2. Enable Socket Mode under "Socket Mode" settings
  3. Generate an App-Level Token with `connections:write` scope (SLACK_APP_TOKEN)
  4. Under "OAuth & Permissions", install the app and copy the Bot Token (SLACK_BOT_TOKEN)
  5. Subscribe to `message.channels`, `message.groups`, `message.im`, `message.mpim` events

  ## Options

  - `:messaging` - The JidoMessaging instance module (required)
  - `:on_message` - Callback function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:instance_id` - Custom instance ID (defaults to module name)
  """

  require Logger

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Slack.Bot

      require Logger

      @messaging_module Keyword.fetch!(opts, :messaging)
      @on_message_callback Keyword.get(opts, :on_message)
      @instance_id Keyword.get(opts, :instance_id, __MODULE__ |> to_string())

      @impl Slack.Bot
      def handle_event("message", %{"subtype" => _subtype}, _bot) do
        # Ignore message subtypes (edits, deletes, bot messages, etc.)
        :ok
      end

      @impl Slack.Bot
      def handle_event("message", payload, _bot) do
        JidoMessaging.Channels.Slack.Handler.process_update(
          payload,
          @messaging_module,
          @instance_id,
          @on_message_callback
        )
      end

      @impl Slack.Bot
      def handle_event(_type, _payload, _bot) do
        :ok
      end
    end
  end

  @doc false
  def process_update(event, messaging_module, instance_id, on_message_callback) do
    alias JidoMessaging.Channels.Slack
    alias JidoMessaging.{Ingest, Deliver}

    # Wrap the payload in the expected format
    payload = %{"type" => "message"} |> Map.merge(normalize_event(event))

    case Slack.transform_incoming(payload) do
      {:ok, incoming} ->
        case Ingest.ingest_incoming(messaging_module, Slack, instance_id, incoming) do
          {:ok, message, context} ->
            handle_message_callback(message, context, on_message_callback, messaging_module)

          {:error, reason} ->
            Logger.warning("[JidoMessaging.Slack] Ingest failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("[JidoMessaging.Slack] Skipping event: #{inspect(reason)}")
    end

    :ok
  end

  defp normalize_event(event) when is_map(event) do
    # Ensure we have string keys for the Slack channel transform
    event
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.new()
  end

  defp handle_message_callback(message, _context, nil, _messaging_module) do
    Logger.debug("[JidoMessaging.Slack] Message received (no handler): #{message.id}")
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
        Logger.warning("[JidoMessaging.Slack] Handler error: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("[JidoMessaging.Slack] Unexpected handler result: #{inspect(other)}")
        :ok
    end
  end
end
