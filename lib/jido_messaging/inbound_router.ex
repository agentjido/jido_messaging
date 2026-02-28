defmodule Jido.Messaging.InboundRouter do
  @moduledoc """
  Inbound routing boundary from raw adapter payloads into runtime ingest.

  This module resolves adapter modules from bridge configuration, then:
  1. verifies/parses webhook requests via `Jido.Chat.Adapter`
  2. canonicalizes routing via `Jido.Chat.process_event/4`
  3. persists message events through `Jido.Messaging.Ingest`
  """

  alias Jido.Chat
  alias Jido.Chat.{Adapter, EventEnvelope, Incoming, WebhookRequest}
  alias Jido.Messaging.{BridgeConfig, ConfigStore, Ingest}

  @type ingest_result ::
          {:ok, {:message, Jido.Chat.LegacyMessage.t(), Ingest.context(), EventEnvelope.t()}}
          | {:ok, {:duplicate, EventEnvelope.t()}}
          | {:ok, {:event, EventEnvelope.t()}}
          | {:ok, :noop}
          | {:error, term()}

  @doc """
  Routes a webhook payload through bridge-config verification + event parsing.

  ## Options

    * `:headers` - request headers map
    * `:path` - request path
    * `:method` - HTTP method
    * `:raw_body` - raw body used by signature verification
    * `:ingest_opts` - options passed to `Jido.Messaging.Ingest.ingest_incoming/5`
  """
  @spec route_webhook(module(), String.t(), map(), keyword()) :: ingest_result()
  def route_webhook(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    ingest_opts = Keyword.get(opts, :ingest_opts, [])

    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         :ok <- ensure_enabled(config),
         {:ok, adapter_module} <- ensure_adapter_module(config),
         request <- build_webhook_request(adapter_module, payload, opts),
         :ok <- Adapter.verify_webhook(adapter_module, request, opts),
         {:ok, event} <- Adapter.parse_event(adapter_module, request, opts) do
      dispatch_event(instance_module, adapter_module, bridge_id, event, ingest_opts, opts)
    end
  end

  @doc """
  Routes a non-webhook payload by direct `transform_incoming/2`.

  Useful for queue/gateway events that already passed transport-level verification.
  """
  @spec route_payload(module(), String.t(), map(), keyword()) :: ingest_result()
  def route_payload(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    ingest_opts = Keyword.get(opts, :ingest_opts, [])

    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         :ok <- ensure_enabled(config),
         {:ok, adapter_module} <- ensure_adapter_module(config),
         {:ok, incoming} <- Adapter.transform_incoming(adapter_module, payload) do
      event =
        EventEnvelope.new(%{
          adapter_name: adapter_type(adapter_module),
          event_type: :message,
          thread_id: Keyword.get(opts, :thread_id, "adapter:#{stringify(incoming.external_room_id)}"),
          channel_id: stringify(incoming.external_room_id),
          message_id: stringify(incoming.external_message_id),
          payload: incoming,
          raw: payload,
          metadata: %{source: :payload, bridge_id: bridge_id}
        })

      dispatch_event(instance_module, adapter_module, bridge_id, event, ingest_opts, opts)
    end
  end

  defp dispatch_event(_instance_module, _adapter_module, _bridge_id, :noop, _ingest_opts, _opts),
    do: {:ok, :noop}

  defp dispatch_event(instance_module, adapter_module, bridge_id, %EventEnvelope{} = event, ingest_opts, opts) do
    adapter_name = adapter_type(adapter_module)

    with {:ok, _chat, routed_event} <- process_event(adapter_name, adapter_module, event, opts) do
      case routed_event.event_type do
        :message ->
          with {:ok, incoming} <- to_incoming(routed_event.payload),
               ingest_result <-
                 Ingest.ingest_incoming(
                   instance_module,
                   adapter_module,
                   bridge_id,
                   normalize_incoming_for_ingest(incoming),
                   ingest_opts
                 ) do
            case ingest_result do
              {:ok, message, context} ->
                {:ok, {:message, message, context, routed_event}}

              {:ok, :duplicate} ->
                {:ok, {:duplicate, routed_event}}

              {:error, _reason} = error ->
                error
            end
          end

        _other ->
          {:ok, {:event, routed_event}}
      end
    end
  end

  defp process_event(adapter_name, adapter_module, event, opts) do
    chat =
      Chat.new(%{
        id: "messaging-inbound:#{adapter_name}",
        adapters: %{adapter_name => adapter_module},
        metadata: %{
          source: :jido_messaging_inbound_router
        }
      })

    Chat.process_event(chat, adapter_name, event, opts)
  end

  defp to_incoming(%Incoming{} = incoming), do: {:ok, incoming}

  defp to_incoming(payload) when is_map(payload) do
    try do
      {:ok, Incoming.new(payload)}
    rescue
      _exception -> {:error, :invalid_message_event_payload}
    end
  end

  defp to_incoming(_payload), do: {:error, :invalid_message_event_payload}

  defp fetch_bridge(instance_module, bridge_id) do
    case ConfigStore.get_bridge_config(instance_module, bridge_id) do
      {:ok, %BridgeConfig{} = config} -> {:ok, config}
      {:error, :not_found} -> {:error, :bridge_not_found}
    end
  end

  defp ensure_enabled(%BridgeConfig{enabled: true}), do: :ok
  defp ensure_enabled(%BridgeConfig{enabled: false}), do: {:error, :bridge_disabled}

  defp ensure_adapter_module(%BridgeConfig{adapter_module: adapter_module}) when is_atom(adapter_module) do
    if Code.ensure_loaded?(adapter_module) do
      {:ok, adapter_module}
    else
      {:error, :invalid_bridge_adapter}
    end
  end

  defp build_webhook_request(adapter_module, payload, opts) do
    WebhookRequest.new(%{
      adapter_name: adapter_type(adapter_module),
      headers: Keyword.get(opts, :headers, %{}),
      path: Keyword.get(opts, :path, "/"),
      method: Keyword.get(opts, :method, "POST"),
      payload: payload,
      raw: Keyword.get(opts, :raw_body, payload),
      metadata: Keyword.get(opts, :request_metadata, %{})
    })
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp normalize_incoming_for_ingest(%Incoming{} = incoming), do: Map.from_struct(incoming)
  defp normalize_incoming_for_ingest(incoming) when is_map(incoming), do: incoming

  defp adapter_type(adapter_module) do
    if function_exported?(adapter_module, :channel_type, 0) do
      adapter_module.channel_type()
    else
      adapter_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()
    end
  end
end
