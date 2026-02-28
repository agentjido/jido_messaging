defmodule Jido.Messaging.WebhookPlug do
  @moduledoc """
  Generic webhook Plug for adapter-backed bridges.

  The host app owns HTTP server setup and mounts this Plug, providing:
    * `:instance_module` - messaging instance module (`use Jido.Messaging`)
    * `:bridge_id` - fixed bridge id, or `:bridge_id_resolver` function
  """

  import Plug.Conn

  alias Jido.Chat.WebhookResponse

  @behaviour Plug

  @type resolver :: (Plug.Conn.t() -> String.t() | nil)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    with {:ok, instance_module} <- fetch_instance_module(opts),
         {:ok, bridge_id} <- resolve_bridge_id(conn, opts),
         {:ok, raw_body, conn} <- read_raw_body(conn, opts),
         {:ok, payload} <- decode_payload(raw_body),
         request_meta <- request_meta(conn, raw_body),
         {:ok, response, _outcome} <-
           Jido.Messaging.route_webhook_request(
             instance_module,
             bridge_id,
             request_meta,
             payload,
             Keyword.get(opts, :route_opts, [])
           ) do
      send_webhook_response(conn, response)
    else
      {:error, :missing_instance_module} ->
        send_webhook_response(conn, WebhookResponse.error(500, %{error: "missing_instance_module"}))

      {:error, :missing_bridge_id} ->
        send_webhook_response(conn, WebhookResponse.error(400, %{error: "missing_bridge_id"}))

      {:error, :invalid_json} ->
        send_webhook_response(conn, WebhookResponse.error(400, %{error: "invalid_json"}))

      {:error, {:read_body_failed, reason}} ->
        send_webhook_response(
          conn,
          WebhookResponse.error(read_body_error_status(reason), %{error: "request_body_read_failed"})
        )
    end
  end

  defp fetch_instance_module(opts) do
    case Keyword.get(opts, :instance_module) do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :missing_instance_module}
    end
  end

  defp resolve_bridge_id(conn, opts) do
    case Keyword.get(opts, :bridge_id) do
      bridge_id when is_binary(bridge_id) and bridge_id != "" ->
        {:ok, bridge_id}

      _ ->
        resolve_bridge_id_with_resolver(conn, opts)
    end
  end

  defp resolve_bridge_id_with_resolver(conn, opts) do
    case Keyword.get(opts, :bridge_id_resolver) do
      resolver when is_function(resolver, 1) ->
        case resolver.(conn) do
          bridge_id when is_binary(bridge_id) and bridge_id != "" -> {:ok, bridge_id}
          _ -> {:error, :missing_bridge_id}
        end

      _ ->
        {:error, :missing_bridge_id}
    end
  end

  defp read_raw_body(conn, opts) do
    read_opts = Keyword.get(opts, :read_body_opts, [])

    case read_body(conn, read_opts) do
      {:ok, raw_body, conn} ->
        {:ok, raw_body, conn}

      {:more, partial, conn} ->
        collect_body_chunks(conn, partial, read_opts)

      {:error, reason} ->
        {:error, {:read_body_failed, reason}}
    end
  end

  defp collect_body_chunks(conn, acc, read_opts) do
    case read_body(conn, read_opts) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> collect_body_chunks(conn, acc <> chunk, read_opts)
      {:error, reason} -> {:error, {:read_body_failed, reason}}
    end
  end

  defp decode_payload(raw_body) when is_binary(raw_body) do
    case String.trim(raw_body) do
      "" ->
        {:ok, %{}}

      _ ->
        case Jason.decode(raw_body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          {:ok, _other} -> {:error, :invalid_json}
          {:error, _reason} -> {:error, :invalid_json}
        end
    end
  end

  defp request_meta(conn, raw_body) do
    %{
      headers: headers_map(conn.req_headers),
      path: conn.request_path,
      method: conn.method,
      raw_body: raw_body
    }
  end

  defp headers_map(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp send_webhook_response(conn, %WebhookResponse{} = response) do
    conn =
      Enum.reduce(response.headers, conn, fn {key, value}, acc ->
        put_resp_header(acc, to_string(key), to_string(value))
      end)

    body = encode_body(response.body)

    conn
    |> put_resp_content_type(content_type(response.body))
    |> send_resp(response.status, body)
  end

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: Jason.encode!(body)

  defp content_type(nil), do: "text/plain"
  defp content_type(body) when is_binary(body), do: "text/plain"
  defp content_type(_), do: "application/json"

  defp read_body_error_status(:timeout), do: 408
  defp read_body_error_status(:too_large), do: 413
  defp read_body_error_status({:too_large, _}), do: 413
  defp read_body_error_status(_), do: 400
end
