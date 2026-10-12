defmodule Jido.Messaging.InboundRouter do
  @moduledoc false
  alias Jido.Chat.{WebhookRequest, WebhookResponse}
  alias Jido.Messaging.{ConfigStore, IngressSink, Runtime}

  @doc false
  def route_payload(instance, bridge, payload, opts \\ []) do
    with {:ok, binding} <- binding(instance, bridge),
         {:ok, delivery} <- Jido.Chat.normalize_event(binding, payload) do
      IngressSink.emit(instance, bridge, delivery, opts)
    end
  end

  @doc false
  def route_webhook(instance, bridge, payload, opts \\ []) do
    meta = Map.new(Keyword.take(opts, [:headers, :path, :method, :raw_body]))
    with {:ok, _response, result} <- route_webhook_request(instance, bridge, meta, payload, opts), do: result
  end

  @doc false
  def route_webhook_request(instance, bridge, meta, payload, opts \\ []) do
    with {:ok, binding} <- binding(instance, bridge) do
      request =
        WebhookRequest.new(%{
          adapter_name: binding.adapter.channel_type(),
          payload: payload,
          headers: meta[:headers] || %{},
          method: meta[:method] || "POST",
          path: meta[:path] || "/",
          raw: meta[:raw_body]
        })

      result =
        with :ok <- verify(binding, request),
             {:ok, delivery} <- Jido.Chat.normalize_event(binding, request) do
          IngressSink.emit(instance, bridge, delivery, opts)
        end

      case result do
        {:error, reason} -> Jido.Messaging.BridgeServer.mark_error(instance, bridge, reason)
        _ -> :ok
      end

      {:ok, format(binding, request, result), result}
    else
      {:error, reason} = error -> {:ok, WebhookResponse.error(status(reason), %{error: "ingress_rejected"}), error}
    end
  end

  defp binding(instance, id) do
    with {:ok, config} <- ConfigStore.get_bridge_config(instance, id),
         true <- config.enabled,
         {:ok, binding} <-
           Runtime.ensure_binding(instance.__jido_messaging__(:runtime), config.adapter_module, id,
             bridge_config: config
           ) do
      {:ok, binding}
    else
      false -> {:error, :bridge_disabled}
      {:error, :not_found} -> {:error, :bridge_not_found}
      error -> error
    end
  end

  defp verify(binding, request) do
    if function_exported?(binding.adapter, :verify_webhook, 2),
      do: binding.adapter.verify_webhook(request, binding.options),
      else: {:error, :unsupported}
  end

  defp format(binding, request, result) do
    if function_exported?(binding.adapter, :format_webhook_response, 2) do
      case binding.adapter.format_webhook_response(result, Keyword.put(binding.options, :request, request)) do
        %WebhookResponse{} = response -> response
        {:ok, %WebhookResponse{} = response} -> response
        map when is_map(map) -> WebhookResponse.new(map)
        _ -> default(result)
      end
    else
      default(result)
    end
  end

  defp default({:ok, _}), do: WebhookResponse.accepted()
  defp default({:error, :invalid_signature}), do: WebhookResponse.error(401, %{error: "invalid_signature"})
  defp default({:error, _}), do: WebhookResponse.error(400, %{error: "ingress_rejected"})
  defp status(:bridge_not_found), do: 404
  defp status(:bridge_disabled), do: 409
  defp status(_), do: 400
end
