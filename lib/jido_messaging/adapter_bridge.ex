defmodule Jido.Messaging.AdapterBridge do
  @moduledoc """
  Runtime bridge between `Jido.Messaging` and `Jido.Chat.Adapter`.

  This module is the only boundary used by the messaging runtime for outbound
  operations and adapter capability/failure normalization.
  """

  alias Jido.Chat.{Adapter, Response}

  @type failure_class :: :recoverable | :degraded | :fatal
  @type failure_disposition :: :retry | :degrade | :crash

  @doc "Returns adapter channel type, falling back to module name inference."
  @spec channel_type(module()) :: atom()
  def channel_type(adapter_module) when is_atom(adapter_module) do
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

  @doc """
  Returns messaging content capabilities for an adapter.

  Adapters may expose either:
  - `content_capabilities/0` (preferred), or
  - `capabilities/0` list (legacy), or
  - `Jido.Chat.Adapter.capabilities/1` matrix (fallback inference).
  """
  @spec capabilities(module()) :: [atom()]
  def capabilities(adapter_module) when is_atom(adapter_module) do
    cond do
      function_exported?(adapter_module, :content_capabilities, 0) ->
        adapter_module.content_capabilities()
        |> normalize_capability_list()

      function_exported?(adapter_module, :capabilities, 0) ->
        case adapter_module.capabilities() do
          caps when is_list(caps) -> normalize_capability_list(caps)
          caps when is_map(caps) -> infer_content_capabilities(caps)
          _ -> [:text]
        end

      true ->
        adapter_module
        |> Adapter.capabilities()
        |> infer_content_capabilities()
    end
  end

  @doc "Checks whether adapter supports a messaging capability."
  @spec supports?(module(), atom()) :: boolean()
  def supports?(adapter_module, capability) when is_atom(capability) do
    capability in capabilities(adapter_module)
  end

  @doc "Normalizes outbound send through canonical adapter boundary."
  @spec send_message(module(), String.t() | integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(adapter_module, external_room_id, text, opts \\ [])
      when is_atom(adapter_module) and is_binary(text) and is_list(opts) do
    with {:ok, response} <- Adapter.send_message(adapter_module, external_room_id, text, opts) do
      {:ok, response_to_map(response)}
    end
  end

  @doc "Normalizes outbound edit through canonical adapter boundary."
  @spec edit_message(module(), String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def edit_message(adapter_module, external_room_id, external_message_id, text, opts \\ [])
      when is_atom(adapter_module) and is_binary(text) and is_list(opts) do
    with {:ok, response} <-
           Adapter.edit_message(adapter_module, external_room_id, external_message_id, text, opts) do
      {:ok, response_to_map(response)}
    end
  end

  @doc """
  Sends media payload when adapter provides a native callback.

  Returns `{:error, :unsupported}` when native media send is not implemented.
  """
  @spec send_media(module(), String.t() | integer(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_media(adapter_module, external_room_id, payload, opts \\ [])
      when is_atom(adapter_module) and is_map(payload) and is_list(opts) do
    if function_exported?(adapter_module, :send_media, 3) do
      normalize_legacy_send_result(adapter_module.send_media(external_room_id, payload, opts))
    else
      {:error, :unsupported}
    end
  end

  @doc """
  Edits media payload when adapter provides a native callback.

  Returns `{:error, :unsupported}` when native media edit is not implemented.
  """
  @spec edit_media(
          module(),
          String.t() | integer(),
          String.t() | integer(),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def edit_media(adapter_module, external_room_id, external_message_id, payload, opts \\ [])
      when is_atom(adapter_module) and is_map(payload) and is_list(opts) do
    if function_exported?(adapter_module, :edit_media, 4) do
      normalize_legacy_send_result(adapter_module.edit_media(external_room_id, external_message_id, payload, opts))
    else
      {:error, :unsupported}
    end
  end

  @doc """
  Returns listener child specs for an adapter, defaulting to no listeners.

  Runtime passes a standard listener context in `opts`:
    * `:instance_module` - messaging runtime instance module
    * `:bridge_id` - bridge identifier
    * `:bridge_config` - resolved bridge config
    * `:settings` - bridge config opts map
    * `:ingress` - normalized ingress settings map
    * `:sink_mfa` - sink callback MFA `{module, function, base_args}`
  """
  @spec listener_child_specs(module(), String.t(), keyword()) ::
          {:ok, [Supervisor.child_spec()]} | {:error, map()}
  def listener_child_specs(adapter_module, bridge_id, opts \\ [])
      when is_atom(adapter_module) and is_binary(bridge_id) and is_list(opts) do
    if function_exported?(adapter_module, :listener_child_specs, 2) do
      try do
        case adapter_module.listener_child_specs(bridge_id, opts) do
          {:ok, specs} when is_list(specs) ->
            {:ok, specs}

          {:error, reason} ->
            {:error, callback_failure(adapter_module, :listener_child_specs, reason)}

          other ->
            {:error, callback_failure(adapter_module, :listener_child_specs, {:invalid_return, other})}
        end
      rescue
        exception ->
          {:error, callback_failure(adapter_module, :listener_child_specs, {:exception, exception})}
      catch
        kind, reason ->
          {:error, callback_failure(adapter_module, :listener_child_specs, {kind, reason})}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Verifies inbound sender when adapter supports verification.

  Default is permissive `:ok`.
  """
  @spec verify_sender(module(), map(), map()) ::
          :ok | {:ok, map()} | {:error, term()}
  def verify_sender(adapter_module, incoming_message, raw_payload)
      when is_atom(adapter_module) and is_map(incoming_message) and is_map(raw_payload) do
    if function_exported?(adapter_module, :verify_sender, 2) do
      adapter_module.verify_sender(incoming_message, raw_payload)
    else
      :ok
    end
  end

  @doc """
  Sanitizes outbound payload when adapter provides custom sanitize callback.

  Default is passthrough `{:ok, outbound}`.
  """
  @spec sanitize_outbound(module(), term(), keyword()) ::
          {:ok, term()} | {:ok, term(), map()} | {:error, term()}
  def sanitize_outbound(adapter_module, outbound, opts \\ [])
      when is_atom(adapter_module) and is_list(opts) do
    if function_exported?(adapter_module, :sanitize_outbound, 2) do
      adapter_module.sanitize_outbound(outbound, opts)
    else
      {:ok, outbound}
    end
  end

  @doc "Classifies adapter failures into retry/degrade/crash classes."
  @spec classify_failure(term()) :: failure_class()
  def classify_failure(reason)

  def classify_failure(%{class: class}) when class in [:recoverable, :degraded, :fatal], do: class
  def classify_failure(%{reason: reason}), do: classify_failure(reason)
  def classify_failure(:timeout), do: :recoverable
  def classify_failure({:timeout, _}), do: :recoverable
  def classify_failure(:econnrefused), do: :recoverable
  def classify_failure(:closed), do: :recoverable
  def classify_failure(:nxdomain), do: :recoverable
  def classify_failure(:network_error), do: :recoverable
  def classify_failure({:network_error, _}), do: :recoverable
  def classify_failure({:api_error, :timeout}), do: :recoverable
  def classify_failure({:api_error, :closed}), do: :recoverable
  def classify_failure({:task_exit, _}), do: :recoverable
  def classify_failure({:exception, _}), do: :recoverable
  def classify_failure({:http_error, status}) when is_integer(status) and status >= 500, do: :recoverable
  def classify_failure({:http_status, status}) when is_integer(status) and status >= 500, do: :recoverable
  def classify_failure({:rate_limited, _}), do: :recoverable

  def classify_failure(:unsupported), do: :degraded
  def classify_failure({:unsupported, _}), do: :degraded
  def classify_failure({:unsupported_method, _}), do: :degraded
  def classify_failure({:media_policy_denied, _}), do: :degraded
  def classify_failure({:policy_denied, _, _, _}), do: :degraded
  def classify_failure({:invalid_return, _}), do: :fatal
  def classify_failure({:invalid_request, _}), do: :fatal
  def classify_failure({:unsupported_operation, _}), do: :fatal
  def classify_failure(_), do: :fatal

  @doc "Maps failure class to runtime disposition."
  @spec failure_disposition(failure_class() | map() | term()) :: failure_disposition()
  def failure_disposition(reason_or_failure) do
    reason_or_failure
    |> classify_failure()
    |> case do
      :recoverable -> :retry
      :degraded -> :degrade
      :fatal -> :crash
    end
  end

  defp normalize_legacy_send_result({:ok, %Response{} = response}), do: {:ok, response_to_map(response)}
  defp normalize_legacy_send_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_legacy_send_result({:ok, result}), do: {:ok, %{message_id: result}}
  defp normalize_legacy_send_result({:error, _reason} = error), do: error
  defp normalize_legacy_send_result(other), do: {:error, {:invalid_return, other}}

  defp normalize_capability_list(caps) when is_list(caps) do
    caps
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> then(fn caps ->
      if :text in caps, do: caps, else: [:text | caps]
    end)
  end

  defp infer_content_capabilities(matrix) when is_map(matrix) do
    caps = [:text]

    caps =
      if capability_enabled?(matrix, :stream) do
        [:streaming | caps]
      else
        caps
      end

    caps =
      if capability_enabled?(matrix, :add_reaction) or capability_enabled?(matrix, :remove_reaction) do
        [:reactions | caps]
      else
        caps
      end

    caps =
      if capability_enabled?(matrix, :list_threads) or capability_enabled?(matrix, :fetch_thread) do
        [:threads | caps]
      else
        caps
      end

    caps =
      if capability_enabled?(matrix, :start_typing) do
        [:typing | caps]
      else
        caps
      end

    caps
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp capability_enabled?(matrix, key) do
    case Map.get(matrix, key) do
      :native -> true
      :fallback -> true
      _ -> false
    end
  end

  defp callback_failure(adapter_module, callback, reason) do
    class = classify_failure(reason)

    %{
      type: :adapter_callback_failure,
      adapter: adapter_module,
      callback: callback,
      class: class,
      disposition: failure_disposition(class),
      reason: reason
    }
  end

  defp response_to_map(%Response{} = response) do
    %{
      message_id: response.message_id || response.external_message_id,
      external_message_id: response.external_message_id || response.message_id,
      external_room_id: response.external_room_id,
      status: response.status,
      channel_type: response.channel_type,
      timestamp: response.timestamp,
      raw: response.raw,
      metadata: response.metadata
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
