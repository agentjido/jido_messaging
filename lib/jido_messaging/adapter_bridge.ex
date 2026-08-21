defmodule Jido.Messaging.AdapterBridge do
  @moduledoc """
  Runtime bridge between `Jido.Messaging` and `Jido.Chat.Adapter`.

  This module is the only boundary used by the messaging runtime for outbound
  operations and adapter capability/failure normalization.
  """

  alias Jido.Chat.{Adapter, Capabilities, FileUpload, PostPayload, Response}

  @type failure_class :: :recoverable | :degraded | :fatal
  @type failure_disposition :: :retry | :degrade | :crash

  @doc "Returns adapter channel type, falling back to module name inference."
  @spec channel_type(module()) :: atom()
  def channel_type(adapter_module) when is_atom(adapter_module) do
    if callback_exported?(adapter_module, :channel_type, 0) do
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
      callback_exported?(adapter_module, :content_capabilities, 0) ->
        adapter_module.content_capabilities()
        |> normalize_capability_list()

      callback_exported?(adapter_module, :capabilities, 0) ->
        case adapter_module.capabilities() do
          caps when is_list(caps) -> normalize_capability_list(caps)
          _ -> Capabilities.channel_capabilities(adapter_module)
        end

      true ->
        Capabilities.channel_capabilities(adapter_module)
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

  @doc "Marks a provider message as read through the canonical adapter boundary."
  @spec mark_as_read(module(), term(), term(), keyword()) :: :ok | {:error, term()}
  def mark_as_read(adapter_module, external_room_id, external_message_id, opts \\ [])
      when is_atom(adapter_module) and is_list(opts) do
    Adapter.mark_as_read(adapter_module, external_room_id, external_message_id, opts)
  end

  @doc """
  Sends media payload through the canonical adapter boundary.

  Preference order:

  1. adapter-native `send_media/3`
  2. canonical `post_message/4` or `send_file/4` fallback through `Jido.Chat.Adapter`
  """
  @spec send_media(module(), String.t() | integer(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_media(adapter_module, external_room_id, payload, opts \\ [])
      when is_atom(adapter_module) and is_map(payload) and is_list(opts) do
    cond do
      callback_exported?(adapter_module, :send_media, 3) ->
        normalize_send_result(adapter_module.send_media(external_room_id, payload, opts))

      canonical_media_send_available?(adapter_module) ->
        payload
        |> media_payload_to_post_payload()
        |> then(&Adapter.post_message(adapter_module, external_room_id, &1, opts))
        |> normalize_send_result()

      true ->
        {:error, :unsupported}
    end
  end

  @doc """
  Edits media payload through adapter-native or replacement behavior.

  Preference order:

  1. adapter-native `edit_media/4`
  2. replacement edit: send the new media and delete the old message
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
    cond do
      callback_exported?(adapter_module, :edit_media, 4) ->
        normalize_send_result(adapter_module.edit_media(external_room_id, external_message_id, payload, opts))

      canonical_media_edit_available?(adapter_module) ->
        replacement_opts = Keyword.put_new(opts, :replacement_for, external_message_id)

        with {:ok, replacement} <- send_media(adapter_module, external_room_id, payload, replacement_opts) do
          delete_result =
            Adapter.delete_message(adapter_module, external_room_id, external_message_id, opts)

          {:ok, attach_replacement_metadata(replacement, external_message_id, delete_result)}
        end

      true ->
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
    if callback_exported?(adapter_module, :listener_child_specs, 2) do
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
  Ensures an adapter-scoped provider ingress subscription.

  The callback is intentionally optional and lives outside the core
  `Jido.Chat.Adapter` behaviour. Adapter packages can implement
  `ensure_ingress_subscription/2` when the provider supports control-plane
  webhook/event subscription provisioning.
  """
  @spec ensure_ingress_subscription(module(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def ensure_ingress_subscription(adapter_module, bridge_id, opts \\ [])
      when is_atom(adapter_module) and is_binary(bridge_id) and is_list(opts) do
    call_subscription_callback(adapter_module, :ensure_ingress_subscription, [bridge_id, opts])
  end

  @doc "Lists adapter-scoped provider ingress subscriptions."
  @spec list_ingress_subscriptions(module(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def list_ingress_subscriptions(adapter_module, bridge_id, opts \\ [])
      when is_atom(adapter_module) and is_binary(bridge_id) and is_list(opts) do
    call_subscription_callback(adapter_module, :list_ingress_subscriptions, [bridge_id, opts])
  end

  @doc "Deletes an adapter-scoped provider ingress subscription."
  @spec delete_ingress_subscription(module(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def delete_ingress_subscription(adapter_module, bridge_id, subscription_id, opts \\ [])
      when is_atom(adapter_module) and is_binary(bridge_id) and is_binary(subscription_id) and is_list(opts) do
    call_subscription_callback(adapter_module, :delete_ingress_subscription, [bridge_id, subscription_id, opts])
  end

  @doc """
  Verifies inbound sender when adapter supports verification.

  Default is permissive `:ok`.
  """
  @spec verify_sender(module(), map(), map()) ::
          :ok | {:ok, map()} | {:error, term()}
  def verify_sender(adapter_module, incoming_message, raw_payload)
      when is_atom(adapter_module) and is_map(incoming_message) and is_map(raw_payload) do
    if callback_exported?(adapter_module, :verify_sender, 2) do
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
    if callback_exported?(adapter_module, :sanitize_outbound, 2) do
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

  defp normalize_send_result({:ok, %Response{} = response}), do: {:ok, response_to_map(response)}
  defp normalize_send_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_send_result({:ok, result}), do: {:ok, %{message_id: result}}
  defp normalize_send_result({:error, _reason} = error), do: error
  defp normalize_send_result(other), do: {:error, {:invalid_return, other}}

  defp call_subscription_callback(adapter_module, callback, args) do
    arity = length(args)

    if callback_exported?(adapter_module, callback, arity) do
      try do
        case apply(adapter_module, callback, args) do
          {:ok, result} ->
            {:ok, result}

          :ok ->
            {:ok, %{}}

          {:error, :unsupported} ->
            {:error, :unsupported}

          {:error, {:unsupported, _reason} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, callback_failure(adapter_module, callback, reason)}

          other ->
            {:error, callback_failure(adapter_module, callback, {:invalid_return, other})}
        end
      rescue
        exception ->
          {:error, callback_failure(adapter_module, callback, {:exception, exception})}
      catch
        kind, reason ->
          {:error, callback_failure(adapter_module, callback, {kind, reason})}
      end
    else
      {:error, :unsupported}
    end
  end

  defp callback_exported?(adapter_module, callback, arity) do
    Code.ensure_loaded?(adapter_module) and function_exported?(adapter_module, callback, arity)
  end

  defp canonical_media_send_available?(adapter_module) do
    callback_exported?(adapter_module, :send_file, 3) or
      callback_exported?(adapter_module, :post_message, 3)
  end

  defp canonical_media_edit_available?(adapter_module) do
    callback_exported?(adapter_module, :delete_message, 3) and
      (callback_exported?(adapter_module, :send_media, 3) or
         canonical_media_send_available?(adapter_module))
  end

  defp normalize_capability_list(caps) when is_list(caps) do
    caps
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> then(fn caps ->
      if :text in caps, do: caps, else: [:text | caps]
    end)
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

  defp media_payload_to_post_payload(payload) when is_map(payload) do
    metadata = media_payload_metadata(payload)

    file =
      FileUpload.new(%{
        kind: payload[:kind] || payload["kind"],
        url: payload[:url] || payload["url"],
        path: payload[:path] || payload["path"],
        data: payload[:data] || payload["data"],
        media_type: payload[:media_type] || payload["media_type"],
        filename: payload[:filename] || payload["filename"],
        size_bytes: payload[:size_bytes] || payload["size_bytes"],
        width: payload[:width] || payload["width"],
        height: payload[:height] || payload["height"],
        duration: payload[:duration] || payload["duration"],
        metadata: metadata
      })

    attrs =
      %{
        files: [file],
        metadata: metadata
      }
      |> maybe_put_post_text(media_payload_caption(payload))

    PostPayload.new(attrs)
  end

  defp media_payload_metadata(payload) when is_map(payload) do
    (payload[:metadata] || payload["metadata"] || %{})
    |> maybe_put_map_value(:thumbnail_url, payload[:thumbnail_url] || payload["thumbnail_url"])
    |> maybe_put_map_value(:alt_text, payload[:alt_text] || payload["alt_text"])
    |> maybe_put_map_value(:transcript, payload[:transcript] || payload["transcript"])
  end

  defp media_payload_caption(payload) when is_map(payload) do
    payload[:alt_text] || payload["alt_text"] || payload[:transcript] || payload["transcript"]
  end

  defp maybe_put_post_text(attrs, nil), do: attrs
  defp maybe_put_post_text(attrs, ""), do: attrs

  defp maybe_put_post_text(attrs, text) when is_binary(text) do
    Map.merge(attrs, %{text: text, formatted: text, fallback_text: text})
  end

  defp attach_replacement_metadata(result, replaced_message_id, delete_result) when is_map(result) do
    metadata =
      result
      |> Map.get(:metadata, %{})
      |> Map.put(:replacement, replacement_metadata(replaced_message_id, delete_result))

    result
    |> Map.put(:metadata, metadata)
    |> Map.put(:status, :edited)
  end

  defp replacement_metadata(replaced_message_id, :ok) do
    %{
      replaced_message_id: replaced_message_id,
      delete_status: :deleted
    }
  end

  defp replacement_metadata(replaced_message_id, {:error, reason}) do
    %{
      replaced_message_id: replaced_message_id,
      delete_status: :delete_failed,
      delete_reason: reason
    }
  end

  defp maybe_put_map_value(map, _key, nil), do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)
end
