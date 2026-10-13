defmodule Jido.Messaging.AdapterBridge do
  @moduledoc """
  Runtime bridge between `Jido.Messaging` and `Jido.Chat.Adapter`.

  This module is the only boundary used by the messaging runtime for outbound
  operations and adapter capability/failure normalization.
  """

  alias Jido.Chat.{Binding, Capabilities, FileUpload, PostPayload}
  alias Jido.Messaging.Runtime

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

  @doc false
  @spec send_message(module(), term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(adapter, room, text, opts \\ []),
    do: operation(adapter, :send_message, %{"room_id" => to_string(room), "text" => text}, opts)

  @doc false
  @spec edit_message(module(), term(), term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def edit_message(adapter, room, message, text, opts \\ []),
    do:
      operation(
        adapter,
        :edit_message,
        %{"room_id" => to_string(room), "message_id" => to_string(message), "text" => text},
        opts
      )

  @doc false
  @spec mark_as_read(module(), term(), term(), keyword()) :: :ok | {:error, term()}
  def mark_as_read(adapter, room, message, opts \\ []) do
    case operation(adapter, :mark_as_read, %{"room_id" => to_string(room), "message_id" => to_string(message)}, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  @spec send_media(module(), term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_media(adapter, room, payload, opts \\ []) do
    with {:ok, binding} <- configured_binding(adapter, opts),
         file <- media_payload_to_post_payload(payload) |> PostPayload.upload_candidates() |> List.first(),
         {:ok, ref} <- media_resource(binding, file, opts[:request_id]) do
      operation(
        adapter,
        :send_file,
        %{"room_id" => to_string(room), "resource_ref" => ref},
        Keyword.put(opts, :binding, binding)
      )
    end
  end

  @doc false
  @spec edit_media(module(), term(), term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def edit_media(adapter, room, message, payload, opts \\ []) do
    with {:ok, replacement} <- send_media(adapter, room, payload, stage_options(opts, :upload)) do
      deleted =
        operation(
          adapter,
          :delete_message,
          %{"room_id" => to_string(room), "message_id" => to_string(message)},
          stage_options(opts, :delete)
        )

      {:ok, attach_replacement_metadata(replacement, message, deleted)}
    end
  end

  defp stage_options(opts, stage) do
    case opts[:request_id] do
      id when is_binary(id) ->
        stage_id = :crypto.hash(:sha256, :erlang.term_to_binary({:media_replacement, id, stage}))
        Keyword.put(opts, :request_id, "media:" <> Base.url_encode64(stage_id, padding: false))

      _ ->
        opts
    end
  end

  defp media_resource(binding, file, nil), do: Jido.Chat.put_resource(binding, "file", file)

  defp media_resource(binding, file, request_id) do
    key = {:messaging_media_resource, request_id}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(file, [:deterministic]))

    case :ets.lookup(binding.resources, key) do
      [{^key, ^digest, ref}] ->
        {:ok, ref}

      [] ->
        with {:ok, ref} <- Jido.Chat.put_resource(binding, "file", file) do
          if :ets.insert_new(binding.resources, {key, digest, ref}) do
            {:ok, ref}
          else
            :ok = Jido.Chat.cancel_resource(binding, ref)
            media_resource(binding, file, request_id)
          end
        end

      _ ->
        Jido.Chat.Signal.Policy.error(:request_conflict)
    end
  rescue
    ArgumentError -> Jido.Chat.Signal.Policy.error(:invalid_binding)
  end

  @doc false
  @spec configured_binding(module(), keyword()) :: {:ok, Binding.t()} | {:error, term()}
  def configured_binding(adapter, opts) do
    case {opts[:binding], opts[:instance_module], opts[:bridge_id]} do
      {%Binding{adapter: ^adapter} = binding, _, _} ->
        {:ok, binding}

      {nil, instance, id} when is_atom(instance) and not is_nil(instance) and is_binary(id) ->
        Runtime.ensure_binding(instance.__jido_messaging__(:runtime), adapter, id, opts)

      _ ->
        Jido.Chat.Signal.Policy.error(:invalid_binding)
    end
  end

  @doc false
  @spec operation(module(), atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def operation(adapter, operation, data, opts) do
    with {:ok, binding} <- configured_binding(adapter, opts) do
      {_type, {definition, ^operation, _fields, _shape, _schema}} =
        Enum.find(Jido.Chat.Operations.Definitions.all(), fn {_type, {_module, name, _fields, _shape, _schema}} ->
          name == operation
        end)

      id = opts[:request_id] || Jido.Chat.ID.generate!()

      data =
        Enum.reduce([:thread_id, :reply_to_id, :format, :cursor, :limit, :direction, :topic_name], data, fn option,
                                                                                                            data ->
          key = Atom.to_string(option)

          value =
            if option == :thread_id,
              do: opts[:external_thread_id] || opts[:thread_id],
              else: opts[option]

          value =
            if is_atom(value) and not is_nil(value) and key in ["direction", "format"],
              do: Atom.to_string(value),
              else: value

          allowed =
            cond do
              key == "topic_name" ->
                operation == :open_thread

              key == "direction" ->
                operation in [:fetch_messages, :fetch_channel_messages, :list_threads]

              key in ["cursor", "limit"] ->
                operation in [:fetch_messages, :fetch_channel_messages, :list_threads, :load_options]

              true ->
                true
            end

          if is_nil(value) or not allowed, do: data, else: Map.put_new(data, key, value)
        end)

      data = Map.put(data, "request_id", id)
      {:ok, request} = definition.new(data)
      {:ok, request} = Jido.Messaging.Signal.Context.attach(request, parent_signal: opts[:parent_signal])

      case Jido.Chat.execute(binding, request) do
        {:ok, %{type: "jido.chat.operation.completed"} = result} ->
          {:ok, private_result(result.data["result"], operation)}

        {:ok, %{type: "jido.chat.operation.failed"} = result} ->
          {:error, failure_reason(binding, result)}

        error ->
          error
      end
    end
  end

  defp private_result(%{"id" => id} = result, operation) when operation in [:open_thread, :fetch_thread] do
    result
    |> Map.put(:external_thread_id, id)
    |> Map.put(:delivery_external_room_id, result["delivery_room_ref"])
  end

  defp private_result(%{"id" => id} = result, _operation) do
    result
    |> Map.put(:message_id, id)
    |> Map.put(:external_message_id, id)
    |> Map.put(:external_room_id, result["room_id"])
  end

  defp private_result(result, _operation), do: result
  defp failure_reason(_binding, %{data: %{"code" => "unsupported"}}), do: :unsupported

  defp failure_reason(binding, result) do
    Jido.Chat.Operations.Failure.reason_tag(binding, result) ||
      %{
        class: Jido.Chat.Operations.Failure.class(binding, result),
        reason: {:provider_operation_failed, result.data["code"]}
      }
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

  def classify_failure(class) when class in [:recoverable, :degraded, :fatal], do: class
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

  defp normalize_capability_list(caps) when is_list(caps) do
    caps
    |> Enum.filter(&(is_atom(&1) and not is_nil(&1)))
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

  defp media_payload_to_post_payload(payload) when is_map(payload) do
    metadata = media_payload_metadata(payload)

    file =
      FileUpload.new(%{
        kind: media_kind(payload[:kind] || payload["kind"]),
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

  defp media_kind(kind) when is_binary(kind),
    do: Enum.find([:image, :audio, :video, :file], kind, &(Atom.to_string(&1) == kind))

  defp media_kind(kind), do: kind

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

  defp replacement_metadata(replaced_message_id, {:ok, _ack}) do
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
