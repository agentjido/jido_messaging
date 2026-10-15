defmodule Jido.Messaging.ChatActions.SignalResult do
  @moduledoc false
  alias Jido.Chat.Operations.Result
  alias Jido.Messaging.{Events, Runtime}
  alias Jido.Messaging.Signal.{Context, Identity, OperationCompleted, OperationFailed}

  @shapes Jido.Messaging.Operations.Definitions.tool_shapes()

  @doc false
  @spec completed(atom(), map(), term(), map(), keyword()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def completed(action, target, data, audit, opts) do
    with {:ok, result} <- project(action, data, target) do
      completed_result(action, target, result, audit, opts)
    else
      _ -> failed(action, :invalid_provider_result, opts)
    end
  end

  defp completed_result(action, target, result, audit, opts) do
    data = %{
      "operation" => "tool." <> Atom.to_string(action),
      "request_id" => opts[:request_id],
      "bridge_id" => target.bridge_id,
      "result" => result
    }

    signal =
      with {:ok, signal} <- OperationCompleted.new(data, metadata(opts, audit)),
           {:ok, signal} <- Context.attach(signal, parent_signal: opts[:parent_signal]),
           do: {:ok, signal}

    case signal do
      {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} ->
        with {:ok, binding} <- Runtime.binding(target.instance_module.__jido_messaging__(:runtime), target.bridge_id),
             {:ok, ref} <- Jido.Chat.Resources.put(binding, "result", result, []) do
          completed_result(action, target, %{"resource_ref" => ref}, audit, opts)
        end

      other ->
        other
    end
  end

  @doc false
  @spec failed(atom(), atom(), keyword()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def failed(action, code, opts) do
    data = %{
      "operation" => "tool." <> Atom.to_string(action),
      "request_id" => opts[:request_id],
      "code" => Atom.to_string(code),
      "retryable" => false
    }

    with {:ok, signal} <- OperationFailed.new(data, metadata(opts, %{})),
         {:ok, signal} <- Context.attach(signal, parent_signal: opts[:parent_signal]),
         do: {:ok, signal}
  end

  defp metadata(opts, audit) do
    instance = opts[:instance]
    scope = audit[:authorization] && audit[:authorization][:effective_scope]
    room = if(is_map(scope), do: scope["room_id"] || scope[:room_id]) || opts[:room_id]
    source = if instance, do: Events.source(instance), else: "urn:jido:messaging:producer:local"
    [source: source, subject: Identity.room_subject(room)]
  end

  defp project(action, data, _target) when action in [:lookup_user, :lookup_participant] and is_map(data) do
    data = if is_struct(data), do: Map.from_struct(data), else: data
    identity = data[:identity] || data["identity"] || %{}
    data = Map.put(data, :display_name, data[:name] || data["name"] || identity[:display_name] || identity[:name])
    Result.project(:user, data, %{})
  end

  defp project(action, data, target) when is_map_key(@shapes, action),
    do: Result.project(@shapes[action], data, %{"room_id" => target.channel_id})

  defp project(:list_subscriptions, data, _target) when is_list(data),
    do: {:ok, %{"items" => Enum.map(data, &control_item/1)}}

  defp project(action, data, _target) when action in [:ensure_subscription, :delete_subscription] and is_map(data),
    do: {:ok, control_item(data)}

  defp project(action, :ok, _target) when action in [:ensure_subscription, :delete_subscription],
    do: {:ok, %{"acknowledged" => true}}

  defp project(_action, _data, _target), do: {:error, :invalid_provider_result}

  defp control_item(data) do
    data = if is_struct(data), do: Map.from_struct(data), else: data

    id =
      data[:id] || data["id"] || data[:subscription_id] || data["subscription_id"] || data[:external_id] ||
        data["external_id"]

    active = Map.get(data, :active, Map.get(data, "active", (data[:status] || data["status"]) in [:active, "active"]))

    %{"id" => id, "active" => active}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
