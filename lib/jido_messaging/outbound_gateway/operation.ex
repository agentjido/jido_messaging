defmodule Jido.Messaging.OutboundGateway.Operation do
  @moduledoc false
  require Logger

  # Keep the three existing dynamic media-boundary annotations after extraction.
  # Dialyzer infers no return through adapter capability checks at this boundary.
  @dialyzer {:nowarn_function, prepare_adapter: 3}
  @dialyzer {:nowarn_function, media_preflight: 1}
  @dialyzer {:nowarn_function, media_text_fallback: 3}
  alias Jido.Messaging.{MediaPolicy, ProviderCall, Security}
  alias Jido.Messaging.AdapterBridge.Media

  def prepare(instance, request) do
    with {:ok, opts} <- adapter_opts(instance, request),
         {:ok, operation, payload, metadata} <- select_operation(request),
         {:ok, sanitized, security} <- Security.sanitize_outbound(instance, request.channel, payload, opts) do
      context = %{request: request, opts: opts, base_opts: opts, security: security, metadata: metadata, stage: :single}
      prepare_adapter(operation, sanitized, context)
    else
      {:error, _} = error -> {:done, error}
    end
  rescue
    exception -> {:done, {:error, {:exception, exception}}}
  catch
    kind, reason -> {:done, {:error, {kind, reason}}}
  end

  def complete(context, outcome), do: advance(context, ProviderCall.complete_operation(context.provider, outcome))
  def unknown(context), do: {:done, ProviderCall.unknown_operation(context.provider)}

  defp select_operation(%{operation: operation, payload: payload}) when operation in [:send, :edit],
    do: {:ok, operation, payload, nil}

  defp select_operation(request) do
    case media_preflight(request) do
      {:ok_media, payload, metadata} ->
        {:ok, request.operation, payload, %{media: metadata}}

      {:fallback_text, text, metadata} ->
        operation = if request.operation == :send_media, do: :send, else: :edit
        {:ok, operation, text, %{media: metadata}}

      {:error, _} = error ->
        error
    end
  end

  defp prepare_adapter(:send, text, context),
    do:
      prepare_provider(context, :send_message, %{
        "room_id" => to_string(context.request.external_room_id),
        "text" => text
      })

  defp prepare_adapter(:edit, text, context),
    do:
      prepare_provider(context, :edit_message, %{
        "room_id" => to_string(context.request.external_room_id),
        "message_id" => to_string(context.request.external_message_id),
        "text" => text
      })

  defp prepare_adapter(operation, payload, context) when operation in [:send_media, :edit_media] do
    opts = if operation == :edit_media, do: Media.stage_options(context.opts, :upload), else: context.opts
    file = payload |> Media.payload() |> Jido.Chat.PostPayload.upload_candidates() |> List.first()

    with {:ok, ref} <- Media.resource(opts[:binding], file, opts[:request_id]) do
      context = %{context | opts: opts, stage: if(operation == :edit_media, do: :upload, else: :single)}

      prepare_provider(context, :send_file, %{
        "room_id" => to_string(context.request.external_room_id),
        "resource_ref" => ref
      })
    else
      error -> {:done, error}
    end
  end

  defp prepare_provider(context, operation, data) do
    case ProviderCall.prepare_operation(context.request.channel, operation, data, context.opts) do
      {:invoke, invocation, completion} -> {:invoke, invocation, Map.put(context, :provider, completion)}
      {:done, result} -> advance(context, result)
    end
  end

  defp advance(%{stage: :upload} = context, {:ok, replacement}) do
    # Delete has its own stable stage ID. Its result keeps the existing replacement
    # metadata rule, including a successful upload followed by a failed delete.
    opts = Media.stage_options(context.base_opts, :delete)
    context = context |> Map.put(:replacement, replacement) |> Map.put(:stage, :delete) |> Map.put(:opts, opts)

    prepare_provider(context, :delete_message, %{
      "room_id" => to_string(context.request.external_room_id),
      "message_id" => to_string(context.request.external_message_id)
    })
  end

  defp advance(%{stage: :delete} = context, deleted),
    do: result(context, {:ok, Media.replacement(context.replacement, context.request.external_message_id, deleted)})

  defp advance(context, result), do: result(context, result)
  defp result(%{metadata: nil} = context, {:ok, provider}), do: {:done, {:ok, provider, context.security}}
  defp result(context, {:ok, provider}), do: {:done, {:ok, provider, context.security, context.metadata}}
  defp result(_context, error), do: {:done, error}

  defp adapter_opts(instance_module, request) do
    runtime = instance_module.__jido_messaging__(:runtime)

    with {:ok, binding} <-
           Jido.Messaging.Runtime.ensure_binding(runtime, request.channel, request.bridge_id, request.opts) do
      {:ok,
       request.opts
       |> Keyword.merge(binding.options)
       |> Keyword.put(:binding, binding)
       |> Keyword.put(:instance_module, instance_module)
       |> Keyword.put(:bridge_id, request.bridge_id)}
    end
  end

  defp media_preflight(request) do
    media_opts = media_policy_opts(request.opts)

    case MediaPolicy.prepare_outbound(request.payload, request.channel, request.operation, media_opts) do
      {:ok, payload, metadata} ->
        {:ok_media, payload, Map.put(metadata, :operation, request.operation)}

      {:fallback_text, fallback_text, metadata} ->
        Logger.warning(
          "[Jido.Messaging.OutboundGateway] Media fallback applied for #{inspect(request.channel)}: #{inspect(metadata.rejected)}"
        )

        case media_text_fallback(request, fallback_text, metadata) do
          {:ok, text_payload, fallback_metadata} ->
            {:fallback_text, text_payload, fallback_metadata}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason, metadata} ->
        Logger.warning(
          "[Jido.Messaging.OutboundGateway] Media dispatch rejected for #{inspect(request.channel)}: #{inspect(reason)} metadata=#{inspect(metadata)}"
        )

        {:error, reason}
    end
  end

  defp media_text_fallback(request, fallback_text, metadata) do
    case request do
      %{operation: :send_media} ->
        {:ok, fallback_text,
         Map.merge(metadata, %{
           fallback: true,
           fallback_mode: :text_send,
           fallback_operation: :send
         })}

      %{operation: :edit_media, external_message_id: nil} ->
        {:error, :missing_external_message_id}

      %{operation: :edit_media} ->
        {:ok, fallback_text,
         Map.merge(metadata, %{
           fallback: true,
           fallback_mode: :text_edit,
           fallback_operation: :edit
         })}
    end
  end

  defp media_policy_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :media_policy, []) do
      value when is_list(value) -> value
      value when is_map(value) -> Map.to_list(value)
      _ -> []
    end
  end
end
