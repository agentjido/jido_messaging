defmodule Jido.Messaging.IngressSink do
  @moduledoc """
  Shared ingress sink for adapter-owned listener workers.

  This module is the runtime-facing callback target that adapter listeners can
  invoke via `sink_mfa` without compile-time references to platform packages.
  """

  @type mode :: :webhook | :payload

  @doc """
  Emits an inbound payload through runtime ingress.

  Modes:
    * `:webhook` (default) routes via `route_webhook_request/5`
    * `:payload` routes via `route_payload/4`
  """
  @spec emit(module(), String.t(), map(), keyword()) :: term()
  def emit(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    payload = normalize_payload(payload)

    case Keyword.get(opts, :mode, :webhook) do
      :payload ->
        Jido.Messaging.route_payload(instance_module, bridge_id, payload, opts)

      _webhook ->
        request_meta =
          opts
          |> Keyword.get(:request_meta, %{})
          |> normalize_request_meta(opts)

        case Jido.Messaging.route_webhook_request(
               instance_module,
               bridge_id,
               request_meta,
               payload,
               opts
             ) do
          {:ok, _response, outcome} -> outcome
        end
    end
  end

  defp normalize_request_meta(request_meta, opts) when is_map(request_meta) do
    request_meta
    |> Map.put_new(:headers, Keyword.get(opts, :headers, %{}))
    |> Map.put_new(:path, Keyword.get(opts, :path, "/"))
    |> Map.put_new(:method, Keyword.get(opts, :method, "POST"))
    |> Map.put_new(:raw_body, Keyword.get(opts, :raw_body))
  end

  defp normalize_payload(%_{} = struct), do: struct |> Map.from_struct() |> normalize_payload()

  defp normalize_payload(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_payload(value)} end)
  end

  defp normalize_payload(list) when is_list(list), do: Enum.map(list, &normalize_payload/1)
  defp normalize_payload(other), do: other
end
