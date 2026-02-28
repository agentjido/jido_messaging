defmodule Jido.Messaging.InboundRouter do
  @moduledoc """
  Inbound routing boundary from raw adapter payloads into runtime ingest.

  This module resolves adapter modules from bridge configuration, then:
  1. verifies/parses webhook requests via `Jido.Chat.Adapter`
  2. canonicalizes routing via `Jido.Chat.process_event/4`
  3. persists message events through `Jido.Messaging.Ingest`
  """

  alias Jido.Chat
  alias Jido.Chat.{Adapter, EventEnvelope, Incoming, WebhookRequest, WebhookResponse}
  alias Jido.Messaging.{BridgeConfig, BridgeServer, ConfigStore, Ingest, IngressOutcome}

  @type ingest_result ::
          {:ok, {:message, Jido.Chat.LegacyMessage.t(), Ingest.context(), EventEnvelope.t()}}
          | {:ok, {:duplicate, EventEnvelope.t()}}
          | {:ok, {:event, EventEnvelope.t()}}
          | {:ok, :noop}
          | {:error, term()}

  @type webhook_result ::
          {:ok, WebhookResponse.t(), ingest_result()} | {:error, term()}

  @type route_ingress_result :: {:ok, IngressOutcome.t()} | {:error, term()}

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
    request_meta = %{
      headers: Keyword.get(opts, :headers, %{}),
      path: Keyword.get(opts, :path, "/"),
      method: Keyword.get(opts, :method, "POST"),
      raw_body: Keyword.get(opts, :raw_body)
    }

    with {:ok, %IngressOutcome{} = routed} <-
           route_ingress(instance_module, bridge_id, :webhook, request_meta, payload, opts) do
      ingest_result_from_outcome(routed)
    end
  end

  @doc """
  Routes a webhook request and returns both typed HTTP response and ingest outcome.

  `request_meta` accepts:
    * `:headers` - request headers map
    * `:path` - request path
    * `:method` - HTTP method
    * `:raw_body` - raw body used by signature verification
  """
  @spec route_webhook_request(module(), String.t(), map(), map(), keyword()) :: webhook_result()
  def route_webhook_request(instance_module, bridge_id, request_meta, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(request_meta) and is_map(payload) and
             is_list(opts) do
    with {:ok, %IngressOutcome{} = routed} <-
           route_ingress(instance_module, bridge_id, :webhook, request_meta, payload, opts) do
      {:ok, routed.response, ingest_result_from_outcome(routed)}
    end
  end

  @doc """
  Routes ingress through a canonical normalized outcome.

  Supported modes:
    * `:webhook` - verifies/parses request, dispatches event, formats webhook response
    * `:payload` - normalizes payload events for listener-driven ingress
  """
  @spec route_ingress(module(), String.t(), :webhook | :payload, map(), map(), keyword()) :: route_ingress_result()
  def route_ingress(instance_module, bridge_id, :webhook, request_meta, payload, opts)
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(request_meta) and is_map(payload) and
             is_list(opts) do
    ingest_opts = Keyword.get(opts, :ingest_opts, [])

    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         :ok <- ensure_enabled(config),
         {:ok, adapter_module} <- ensure_adapter_module(config) do
      request = build_webhook_request(adapter_module, payload, request_meta)
      format_opts = Keyword.merge(opts, request: request)

      outcome =
        with :ok <- Adapter.verify_webhook(adapter_module, request, opts),
             {:ok, event} <- Adapter.parse_event(adapter_module, request, opts) do
          dispatch_event(instance_module, adapter_module, bridge_id, event, ingest_opts, opts)
        end

      response =
        outcome
        |> webhook_format_result()
        |> format_response(adapter_module, format_opts)

      record_ingress(instance_module, bridge_id, outcome)
      {:ok, normalize_outcome(:webhook, bridge_id, outcome, response)}
    else
      {:error, _reason} = error ->
        response = default_response(error)
        BridgeServer.mark_error(instance_module, bridge_id, error)
        {:ok, normalize_outcome(:webhook, bridge_id, error, response)}
    end
  end

  def route_ingress(instance_module, bridge_id, :payload, _request_meta, payload, opts)
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    ingest_opts = Keyword.get(opts, :ingest_opts, [])
    payload = normalize_payload_input(payload)

    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         :ok <- ensure_enabled(config),
         {:ok, adapter_module} <- ensure_adapter_module(config) do
      outcome =
        case normalize_payload_event(adapter_module, payload, opts) do
          {:ok, :noop} ->
            {:ok, :noop}

          {:ok, %EventEnvelope{} = event} ->
            dispatch_event(instance_module, adapter_module, bridge_id, event, ingest_opts, opts)

          :fallback ->
            with {:ok, incoming} <- Adapter.transform_incoming(adapter_module, payload) do
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

      record_ingress(instance_module, bridge_id, outcome)
      {:ok, normalize_outcome(:payload, bridge_id, outcome, nil)}
    end
  end

  def route_ingress(_instance_module, _bridge_id, _mode, _request_meta, _payload, _opts),
    do: {:error, :invalid_ingress_request}

  @doc """
  Routes a non-webhook payload through canonical event normalization.

  For transport listeners (polling, gateways, queues), this path supports:
    * direct `EventEnvelope` payloads
    * adapter `parse_event/2` normalization when available
    * `transform_incoming/1` fallback for message payloads
  """
  @spec route_payload(module(), String.t(), map(), keyword()) :: ingest_result()
  def route_payload(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    with {:ok, %IngressOutcome{} = routed} <-
           route_ingress(instance_module, bridge_id, :payload, %{}, payload, opts) do
      ingest_result_from_outcome(routed)
    end
  end

  defp normalize_outcome(mode, bridge_id, {:ok, :noop}, response) do
    IngressOutcome.new(%{
      mode: mode,
      bridge_id: bridge_id,
      status: :noop,
      envelope: nil,
      message: nil,
      context: nil,
      response: response,
      error: nil
    })
  end

  defp normalize_outcome(mode, bridge_id, {:ok, {:event, %EventEnvelope{} = event}}, response) do
    IngressOutcome.new(%{
      mode: mode,
      bridge_id: bridge_id,
      status: :event,
      envelope: event,
      message: nil,
      context: nil,
      response: response,
      error: nil
    })
  end

  defp normalize_outcome(mode, bridge_id, {:ok, {:duplicate, %EventEnvelope{} = event}}, response) do
    IngressOutcome.new(%{
      mode: mode,
      bridge_id: bridge_id,
      status: :duplicate,
      envelope: event,
      message: nil,
      context: nil,
      response: response,
      error: nil
    })
  end

  defp normalize_outcome(mode, bridge_id, {:ok, {:message, message, context, %EventEnvelope{} = event}}, response) do
    IngressOutcome.new(%{
      mode: mode,
      bridge_id: bridge_id,
      status: :message,
      envelope: event,
      message: message,
      context: context,
      response: response,
      error: nil
    })
  end

  defp normalize_outcome(mode, bridge_id, {:error, reason}, response) do
    IngressOutcome.new(%{
      mode: mode,
      bridge_id: bridge_id,
      status: :error,
      envelope: nil,
      message: nil,
      context: nil,
      response: response,
      error: reason
    })
  end

  defp ingest_result_from_outcome(%IngressOutcome{status: :noop}), do: {:ok, :noop}

  defp ingest_result_from_outcome(%IngressOutcome{status: :event, envelope: %EventEnvelope{} = event}),
    do: {:ok, {:event, event}}

  defp ingest_result_from_outcome(%IngressOutcome{status: :duplicate, envelope: %EventEnvelope{} = event}),
    do: {:ok, {:duplicate, event}}

  defp ingest_result_from_outcome(%IngressOutcome{
         status: :message,
         message: message,
         context: context,
         envelope: %EventEnvelope{} = event
       }),
       do: {:ok, {:message, message, context, event}}

  defp ingest_result_from_outcome(%IngressOutcome{status: :error, error: reason}), do: {:error, reason}

  defp record_ingress(instance_module, bridge_id, {:ok, _}) do
    BridgeServer.mark_ingress(instance_module, bridge_id)
    :ok
  end

  defp record_ingress(instance_module, bridge_id, {:error, reason}) do
    BridgeServer.mark_error(instance_module, bridge_id, reason)
    :ok
  end

  defp dispatch_event(_instance_module, _adapter_module, _bridge_id, :noop, _ingest_opts, _opts),
    do: {:ok, :noop}

  defp dispatch_event(instance_module, adapter_module, bridge_id, %EventEnvelope{} = event, ingest_opts, opts) do
    adapter_name = adapter_type(adapter_module)

    with {:ok, _chat, routed_event} <- process_event(adapter_name, adapter_module, event, opts) do
      dispatch_routed_event(instance_module, adapter_module, bridge_id, routed_event, ingest_opts)
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

  defp dispatch_routed_event(instance_module, adapter_module, bridge_id, %EventEnvelope{} = routed_event, ingest_opts) do
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

  defp build_webhook_request(adapter_module, payload, request_meta) do
    WebhookRequest.new(%{
      adapter_name: adapter_type(adapter_module),
      headers: Map.get(request_meta, :headers, %{}),
      path: Map.get(request_meta, :path, "/"),
      method: Map.get(request_meta, :method, "POST"),
      payload: payload,
      raw: Map.get(request_meta, :raw_body, payload),
      metadata: Map.get(request_meta, :request_metadata, %{})
    })
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp normalize_incoming_for_ingest(%Incoming{} = incoming), do: Map.from_struct(incoming)
  defp normalize_incoming_for_ingest(incoming) when is_map(incoming), do: incoming

  defp normalize_payload_event(_adapter_module, %EventEnvelope{} = envelope, _opts),
    do: {:ok, envelope}

  defp normalize_payload_event(adapter_module, payload, opts) when is_map(payload) do
    cond do
      event_envelope_shape?(payload) ->
        payload
        |> map_to_envelope(adapter_module)
        |> case do
          {:ok, envelope} -> {:ok, envelope}
          {:error, _reason} -> :fallback
        end

      function_exported?(adapter_module, :parse_event, 2) ->
        request = build_webhook_request(adapter_module, payload, payload_request_meta(opts))

        case Adapter.parse_event(adapter_module, request, opts) do
          {:ok, :noop} ->
            {:ok, :noop}

          {:ok, event} ->
            event
            |> map_to_envelope(adapter_module)
            |> case do
              {:ok, envelope} -> {:ok, envelope}
              {:error, _reason} -> :fallback
            end

          {:error, _reason} ->
            :fallback
        end

      true ->
        :fallback
    end
  end

  defp payload_request_meta(opts) do
    %{
      headers: Keyword.get(opts, :headers, %{}),
      path: Keyword.get(opts, :path, "/payload"),
      method: Keyword.get(opts, :method, "PAYLOAD"),
      raw_body: Keyword.get(opts, :raw_body),
      request_metadata: Keyword.get(opts, :request_metadata, %{})
    }
  end

  defp map_to_envelope(%EventEnvelope{} = envelope, _adapter_module), do: {:ok, envelope}

  defp map_to_envelope(event, adapter_module) when is_map(event) do
    defaults = %{adapter_name: adapter_type(adapter_module)}

    try do
      {:ok, EventEnvelope.new(Map.merge(defaults, event))}
    rescue
      _exception -> {:error, :invalid_event_envelope}
    end
  end

  defp event_envelope_shape?(%EventEnvelope{}), do: true

  defp event_envelope_shape?(map) when is_map(map) do
    Map.has_key?(map, :event_type) or Map.has_key?(map, "event_type")
  end

  defp normalize_payload_input(%_{} = struct),
    do: struct |> Map.from_struct() |> normalize_payload_input()

  defp normalize_payload_input(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_payload_input(value)} end)
  end

  defp normalize_payload_input(list) when is_list(list),
    do: Enum.map(list, &normalize_payload_input/1)

  defp normalize_payload_input(other), do: other

  defp webhook_format_result({:ok, :noop}), do: {:ok, nil, :noop}
  defp webhook_format_result({:ok, {:event, event}}), do: {:ok, nil, event}
  defp webhook_format_result({:ok, {:message, _message, _context, event}}), do: {:ok, nil, event}
  defp webhook_format_result({:ok, {:duplicate, event}}), do: {:ok, nil, event}
  defp webhook_format_result({:error, _reason} = error), do: error

  defp format_response(format_result, adapter_module, opts) do
    if prefer_default_response?(format_result) do
      default_response(format_result)
    else
      case Adapter.format_webhook_response(adapter_module, format_result, opts) do
        {:ok, %WebhookResponse{} = response} -> response
        {:error, _reason} -> default_response(format_result)
      end
    end
  end

  defp prefer_default_response?({:error, :bridge_not_found}), do: true
  defp prefer_default_response?({:error, :bridge_disabled}), do: true
  defp prefer_default_response?({:error, :invalid_bridge_adapter}), do: true
  defp prefer_default_response?({:error, :invalid_signature}), do: true
  defp prefer_default_response?({:error, :invalid_webhook_secret}), do: true
  defp prefer_default_response?(_), do: false

  defp default_response({:error, :bridge_not_found}), do: WebhookResponse.error(404, %{error: "bridge_not_found"})
  defp default_response({:error, :bridge_disabled}), do: WebhookResponse.error(409, %{error: "bridge_disabled"})

  defp default_response({:error, :invalid_bridge_adapter}),
    do: WebhookResponse.error(500, %{error: "invalid_bridge_adapter"})

  defp default_response({:error, :invalid_signature}), do: WebhookResponse.error(401, %{error: "invalid_signature"})

  defp default_response({:error, :invalid_webhook_secret}),
    do: WebhookResponse.error(401, %{error: "invalid_webhook_secret"})

  defp default_response({:error, reason}), do: WebhookResponse.error(400, %{error: normalize_error_reason(reason)})
  defp default_response(_result), do: WebhookResponse.accepted(%{ok: true})

  defp normalize_error_reason(reason) when is_binary(reason), do: reason
  defp normalize_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_error_reason(reason), do: inspect(reason)

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
