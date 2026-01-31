defmodule JidoMessaging.Channels.WhatsApp.Handler do
  @moduledoc """
  WhatsApp webhook handler for use with Phoenix or Plug routers.

  This module provides functions to handle WhatsApp webhook verification and
  message processing, integrating with JidoMessaging's ingest and delivery pipelines.

  ## Usage

  In a Phoenix controller:

      defmodule MyAppWeb.WhatsAppController do
        use MyAppWeb, :controller

        alias JidoMessaging.Channels.WhatsApp.Handler

        @handler_opts %{
          messaging: MyApp.Messaging,
          verify_token: "your_verify_token",
          on_message: &MyApp.MessageHandler.handle/2
        }

        # GET /webhooks/whatsapp - Verification endpoint
        def verify(conn, params) do
          case Handler.verify_webhook(params, @handler_opts.verify_token) do
            {:ok, challenge} ->
              conn
              |> put_resp_content_type("text/plain")
              |> send_resp(200, challenge)

            {:error, :invalid_token} ->
              conn
              |> put_resp_content_type("text/plain")
              |> send_resp(403, "Forbidden")
          end
        end

        # POST /webhooks/whatsapp - Message webhook
        def webhook(conn, params) do
          Handler.process_webhook(params, @handler_opts)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, "OK")
        end
      end

  Add routes in your router:

      scope "/webhooks", MyAppWeb do
        get "/whatsapp", WhatsAppController, :verify
        post "/whatsapp", WhatsAppController, :webhook
      end

  ## Configuration

  WhatsApp Cloud API requires configuration in Meta's Developer Console:

  1. Go to https://developers.facebook.com/apps and select your app
  2. Under "WhatsApp" > "Configuration", set up webhooks:
     - Callback URL: `https://your-domain.com/webhooks/whatsapp`
     - Verify Token: Same value as `:verify_token` option
     - Subscribe to: `messages` webhook field
  3. Configure your app with the access token:

      # config/runtime.exs
      config :whatsapp_elixir,
        token: System.get_env("WHATSAPP_ACCESS_TOKEN"),
        phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID")

  ## Handler Options

  - `:messaging` - The JidoMessaging instance module (required)
  - `:verify_token` - Token for webhook verification (required for verify_webhook/2)
  - `:on_message` - Callback function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:instance_id` - Custom instance ID (defaults to "whatsapp_webhook")
  """

  require Logger

  @doc """
  Verify a WhatsApp webhook subscription request.

  WhatsApp sends a GET request with query parameters to verify your webhook URL.

  ## Parameters

  - `params` - The query parameters from the request (map with string keys)
  - `verify_token` - Your configured verification token

  ## Returns

  - `{:ok, challenge}` - Verification successful, return the challenge string
  - `{:error, :invalid_token}` - Verification failed, token mismatch

  ## Example

      case Handler.verify_webhook(conn.query_params, "my_verify_token") do
        {:ok, challenge} -> send_resp(conn, 200, challenge)
        {:error, :invalid_token} -> send_resp(conn, 403, "Forbidden")
      end
  """
  @spec verify_webhook(map(), String.t()) :: {:ok, String.t()} | {:error, :invalid_token}
  def verify_webhook(params, verify_token) do
    mode = Map.get(params, "hub.mode")
    token = Map.get(params, "hub.verify_token")
    challenge = Map.get(params, "hub.challenge", "")

    if mode == "subscribe" and token == verify_token do
      Logger.info("[JidoMessaging.WhatsApp] Webhook verification successful")
      {:ok, challenge}
    else
      Logger.warning("[JidoMessaging.WhatsApp] Webhook verification failed: invalid token")
      {:error, :invalid_token}
    end
  end

  @doc """
  Process a WhatsApp webhook payload.

  Call this from your POST endpoint handler. The function processes
  the webhook asynchronously and always returns `:ok`.

  ## Parameters

  - `payload` - The JSON-decoded webhook payload (map with string keys)
  - `opts` - Handler options map with `:messaging`, `:on_message`, and optionally `:instance_id`

  ## Example

      def webhook(conn, params) do
        Handler.process_webhook(params, %{
          messaging: MyApp.Messaging,
          on_message: &MyApp.MessageHandler.handle/2
        })

        send_resp(conn, 200, "OK")
      end
  """
  @spec process_webhook(map(), map()) :: :ok
  def process_webhook(payload, opts) do
    messaging = Map.fetch!(opts, :messaging)
    on_message = Map.get(opts, :on_message)
    instance_id = Map.get(opts, :instance_id, "whatsapp_webhook")

    # WhatsApp sends status updates and messages - we only care about messages
    case extract_message_entries(payload) do
      [] ->
        Logger.debug("[JidoMessaging.WhatsApp] Webhook payload contains no messages")

      entries ->
        Enum.each(entries, fn entry ->
          process_update(entry, messaging, instance_id, on_message)
        end)
    end

    :ok
  end

  defp extract_message_entries(%{"entry" => entries}) when is_list(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      changes = Map.get(entry, "changes", [])

      Enum.filter(changes, fn change ->
        value = Map.get(change, "value", %{})
        Map.has_key?(value, "messages")
      end)
    end)
  end

  defp extract_message_entries(_), do: []

  @doc false
  def process_update(change, messaging_module, instance_id, on_message_callback) do
    alias JidoMessaging.Channels.WhatsApp
    alias JidoMessaging.{Ingest, Deliver}

    # Reconstruct the payload format expected by WhatsApp.transform_incoming
    payload = %{"entry" => [%{"changes" => [change]}]}

    case WhatsApp.transform_incoming(payload) do
      {:ok, incoming} ->
        case Ingest.ingest_incoming(messaging_module, WhatsApp, instance_id, incoming) do
          {:ok, message, context} ->
            handle_message_callback(message, context, on_message_callback, messaging_module)

          {:error, reason} ->
            Logger.warning("[JidoMessaging.WhatsApp] Ingest failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("[JidoMessaging.WhatsApp] Skipping payload: #{inspect(reason)}")
    end

    :ok
  end

  defp handle_message_callback(message, _context, nil, _messaging_module) do
    Logger.debug("[JidoMessaging.WhatsApp] Message received (no handler): #{message.id}")
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
        Logger.warning("[JidoMessaging.WhatsApp] Handler error: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("[JidoMessaging.WhatsApp] Unexpected handler result: #{inspect(other)}")
        :ok
    end
  end
end
