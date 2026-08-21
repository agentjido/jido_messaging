defmodule Jido.Messaging.ChatActions.Resolver do
  @moduledoc false

  alias Jido.Chat.MessagingTarget
  alias Jido.Messaging.{AdapterBridge, BridgeConfig, ConfigStore}

  @type resolved :: %{
          required(:instance_module) => module(),
          required(:bridge_id) => String.t(),
          required(:adapter) => atom(),
          required(:adapter_module) => module(),
          required(:channel_id) => String.t(),
          optional(:thread_id) => String.t() | nil,
          optional(:workspace_id) => String.t() | nil,
          required(:adapter_opts) => keyword()
        }

  @doc false
  @spec resolve(map(), map()) :: {:ok, resolved()} | {:error, atom(), map()}
  def resolve(params, context) when is_map(params) and is_map(context) do
    runtime_context = runtime_context(context)

    with {:ok, instance_module} <- fetch_instance(runtime_context),
         {:ok, target} <- fetch_target(params, runtime_context),
         {:ok, bridge_id} <- fetch_bridge_id(target),
         {:ok, %BridgeConfig{} = config} <- fetch_bridge(instance_module, bridge_id),
         {:ok, channel_id} <- fetch_channel_id(target),
         :ok <- validate_adapter_claim(target, config.adapter_module) do
      adapter = AdapterBridge.channel_type(config.adapter_module)
      thread_id = stringify(get(target, :thread_id))
      workspace_id = config.opts |> get(:workspace_id) |> stringify()

      {:ok,
       %{
         instance_module: instance_module,
         bridge_id: config.id,
         adapter: adapter,
         adapter_module: config.adapter_module,
         channel_id: channel_id,
         thread_id: thread_id,
         workspace_id: workspace_id,
         adapter_opts: adapter_opts(instance_module, config, thread_id)
       }}
    end
  end

  @doc false
  @spec runtime_context(map()) :: map()
  def runtime_context(context) do
    get(context, :chat_action) || context
  end

  defp fetch_instance(context) do
    case get(context, :instance_module) do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :missing_runtime_context, %{field: :instance_module}}
    end
  end

  defp fetch_target(params, context) do
    target = get(params, :target) || get(context, :target) || inherited_target(context)

    case target do
      %MessagingTarget{} = value -> {:ok, Map.from_struct(value)}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :missing_target, %{field: :target}}
    end
  end

  defp inherited_target(context) do
    active = get(context, :active_context) || get(context, :msg_context)

    if is_map(active) and get(active, :external_room_id) do
      active
      |> MessagingTarget.from_context()
      |> Map.from_struct()
    end
  end

  defp fetch_bridge_id(target) do
    case get(target, :instance_id) || get(target, :bridge_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when not is_nil(value) -> {:ok, to_string(value)}
      _ -> {:error, :missing_bridge_id, %{field: :target}}
    end
  end

  defp fetch_bridge(instance_module, bridge_id) do
    case ConfigStore.get_bridge_config(instance_module, bridge_id) do
      {:ok, %BridgeConfig{enabled: true} = config} -> {:ok, config}
      {:ok, %BridgeConfig{enabled: false}} -> {:error, :bridge_disabled, %{bridge_id: bridge_id}}
      {:error, :not_found} -> {:error, :bridge_not_found, %{bridge_id: bridge_id}}
    end
  end

  defp fetch_channel_id(target) do
    case get(target, :external_id) || get(target, :external_room_id) || get(target, :channel_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when not is_nil(value) -> {:ok, to_string(value)}
      _ -> {:error, :missing_channel_id, %{field: :target}}
    end
  end

  defp validate_adapter_claim(target, adapter_module) do
    expected = AdapterBridge.channel_type(adapter_module)
    expected_string = Atom.to_string(expected)

    case get(target, :channel_type) do
      nil -> :ok
      ^expected -> :ok
      ^expected_string -> :ok
      _ -> {:error, :target_mismatch, %{field: :channel_type, expected: expected}}
    end
  end

  defp adapter_opts(instance_module, %BridgeConfig{} = config, thread_id) do
    []
    |> Keyword.put(:instance_module, instance_module)
    |> Keyword.put(:bridge_id, config.id)
    |> Keyword.put(:bridge_config, config)
    |> Keyword.put(:credentials, config.credentials)
    |> Keyword.put(:settings, config.opts)
    |> maybe_put(:thread_id, thread_id)
    |> maybe_put(:external_thread_id, thread_id)
  end

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
