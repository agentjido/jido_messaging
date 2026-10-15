defmodule Jido.Messaging.ProviderCall do
  @moduledoc false

  # Transport mechanics only. Callers retain authorization, sanitization,
  # queue, retry, receipt, and publication rules.
  alias Jido.Chat.Binding
  alias Jido.Messaging.{Diagnostics, Runtime}

  @spec execute(Binding.t(), Jido.Signal.t()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def execute(binding, request) do
    started = System.monotonic_time()
    result = Jido.Chat.execute(binding, request)
    Diagnostics.provider_result(binding, request, result, System.monotonic_time() - started)
    result
  end

  # Streaming is a legacy channel interface. Keep its callback arities and
  # return values. It has no typed binding, gateway retry, or authorization.
  @spec legacy_send(module(), term(), String.t(), keyword()) :: term()
  def legacy_send(channel, room, content, opts), do: channel.send_message(room, content, opts)

  @spec legacy_edit(module(), term(), term(), String.t()) :: term()
  def legacy_edit(channel, room, message, content), do: channel.edit_message(room, message, content)

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

      case execute(binding, request) do
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
end
