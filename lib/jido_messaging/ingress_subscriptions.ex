defmodule Jido.Messaging.IngressSubscriptions do
  @moduledoc """
  Bridge-scoped ingress subscription provisioning.

  This module coordinates provider-specific adapter callbacks with the
  messaging runtime control plane. It does not own webhook request routing.
  """

  alias Jido.Messaging.{AdapterBridge, BridgeConfig, ConfigStore, IngressSubscription}

  @type result :: {:ok, IngressSubscription.t()} | {:error, term()}
  @type list_result :: {:ok, [IngressSubscription.t()]} | {:error, term()}

  @doc "Ensure the provider-side ingress subscription for a bridge."
  @spec ensure(module(), String.t(), keyword()) :: result()
  def ensure(instance_module, bridge_id, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_list(opts) do
    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         :ok <- ensure_enabled(config),
         {:ok, adapter_module} <- ensure_adapter_module(config) do
      adapter_name = AdapterBridge.channel_type(adapter_module)
      adapter_opts = subscription_opts(instance_module, bridge_id, config, opts)

      case AdapterBridge.ensure_ingress_subscription(adapter_module, bridge_id, adapter_opts) do
        {:ok, raw_subscription} ->
          with {:ok, subscription} <-
                 normalize_subscription(raw_subscription, bridge_id, adapter_name, adapter_opts, :active),
               {:ok, saved} <- ConfigStore.save_ingress_subscription(instance_module, subscription) do
            {:ok, saved}
          end

        {:error, reason} ->
          {:error, subscription_error(reason, bridge_id, adapter_name)}
      end
    end
  end

  @doc "List provider-side ingress subscriptions for a bridge."
  @spec list(module(), String.t(), keyword()) :: list_result()
  def list(instance_module, bridge_id, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_list(opts) do
    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         {:ok, adapter_module} <- ensure_adapter_module(config) do
      adapter_name = AdapterBridge.channel_type(adapter_module)
      adapter_opts = subscription_opts(instance_module, bridge_id, config, opts)

      case AdapterBridge.list_ingress_subscriptions(adapter_module, bridge_id, adapter_opts) do
        {:ok, raw_subscriptions} ->
          with {:ok, subscriptions} <-
                 normalize_subscription_list(raw_subscriptions, bridge_id, adapter_name, adapter_opts) do
            Enum.each(subscriptions, &ConfigStore.save_ingress_subscription(instance_module, &1))
            {:ok, subscriptions}
          end

        {:error, reason} ->
          if unsupported?(reason) do
            ConfigStore.list_ingress_subscriptions(instance_module, bridge_id, opts)
          else
            {:error, subscription_error(reason, bridge_id, adapter_name)}
          end
      end
    end
  end

  @doc "Delete a provider-side ingress subscription for a bridge."
  @spec delete(module(), String.t(), String.t(), keyword()) :: result()
  def delete(instance_module, bridge_id, subscription_id, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_binary(subscription_id) and is_list(opts) do
    with {:ok, config} <- fetch_bridge(instance_module, bridge_id),
         {:ok, adapter_module} <- ensure_adapter_module(config) do
      adapter_name = AdapterBridge.channel_type(adapter_module)
      adapter_opts = subscription_opts(instance_module, bridge_id, config, opts)

      case AdapterBridge.delete_ingress_subscription(adapter_module, bridge_id, subscription_id, adapter_opts) do
        {:ok, raw_subscription} ->
          _ = ConfigStore.delete_ingress_subscription(instance_module, bridge_id, subscription_id)

          normalize_subscription(
            raw_subscription,
            bridge_id,
            adapter_name,
            Keyword.put(adapter_opts, :subscription_id, subscription_id),
            :deleted
          )

        {:error, reason} ->
          {:error, subscription_error(reason, bridge_id, adapter_name)}
      end
    end
  end

  defp fetch_bridge(instance_module, bridge_id) do
    case ConfigStore.get_bridge_config(instance_module, bridge_id) do
      {:ok, %BridgeConfig{} = config} -> {:ok, config}
      {:error, :not_found} -> {:error, :bridge_not_found}
    end
  end

  defp ensure_enabled(%BridgeConfig{enabled: true}), do: :ok
  defp ensure_enabled(%BridgeConfig{enabled: false}), do: {:error, :bridge_disabled}

  defp ensure_adapter_module(%BridgeConfig{adapter_module: adapter_module}) when is_atom(adapter_module) do
    if Code.ensure_loaded?(adapter_module) do
      {:ok, adapter_module}
    else
      {:error, :invalid_bridge_adapter}
    end
  end

  defp subscription_opts(instance_module, bridge_id, %BridgeConfig{} = config, opts) do
    settings = config.opts
    ingress = ingress_settings(settings)
    target_url = target_url(opts, ingress)

    opts
    |> Keyword.put_new(:instance_module, instance_module)
    |> Keyword.put_new(:bridge_id, bridge_id)
    |> Keyword.put_new(:bridge_config, config)
    |> Keyword.put_new(:credentials, config.credentials)
    |> Keyword.put_new(:settings, settings)
    |> Keyword.put_new(:ingress, ingress)
    |> Keyword.put_new(:adapter_name, AdapterBridge.channel_type(config.adapter_module))
    |> maybe_put_new(:target_url, target_url)
    |> maybe_put_new(:webhook_url, target_url)
  end

  defp ingress_settings(settings) when is_map(settings) do
    Map.get(settings, :ingress) || Map.get(settings, "ingress") || %{}
  end

  defp target_url(opts, ingress) do
    Keyword.get(opts, :target_url) ||
      Keyword.get(opts, :webhook_url) ||
      map_get(ingress, :target_url) ||
      map_get(ingress, :webhook_url)
  end

  defp normalize_subscription_list(raw_subscriptions, bridge_id, adapter_name, opts) do
    raw_subscriptions
    |> subscription_items()
    |> Enum.reduce_while({:ok, []}, fn raw_subscription, {:ok, subscriptions} ->
      case normalize_subscription(raw_subscription, bridge_id, adapter_name, opts, :active) do
        {:ok, subscription} -> {:cont, {:ok, [subscription | subscriptions]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, subscriptions} -> {:ok, Enum.reverse(subscriptions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp subscription_items(items) when is_list(items), do: items
  defp subscription_items(%{subscriptions: items}) when is_list(items), do: items
  defp subscription_items(%{"subscriptions" => items}) when is_list(items), do: items
  defp subscription_items(%{data: items}) when is_list(items), do: items
  defp subscription_items(%{"data" => items}) when is_list(items), do: items
  defp subscription_items(item) when is_map(item), do: [item]
  defp subscription_items(_item), do: []

  defp normalize_subscription(%IngressSubscription{} = subscription, bridge_id, adapter_name, opts, default_status) do
    attrs =
      subscription
      |> Map.from_struct()
      |> Map.put_new(:bridge_id, bridge_id)
      |> Map.put_new(:adapter_name, adapter_name)
      |> Map.put_new(:status, default_status)
      |> Map.put_new(:target_url, Keyword.get(opts, :target_url))
      |> Map.put_new(:subscription_id, Keyword.get(opts, :subscription_id))

    {:ok, IngressSubscription.new(attrs)}
  end

  defp normalize_subscription(raw_subscription, bridge_id, adapter_name, opts, default_status)
       when is_map(raw_subscription) do
    attrs =
      raw_subscription
      |> normalize_map()
      |> Map.put_new(:bridge_id, bridge_id)
      |> Map.put_new(:adapter_name, adapter_name)
      |> Map.put_new(:status, default_status)
      |> Map.put_new(:target_url, Keyword.get(opts, :target_url))
      |> Map.put_new(:subscription_id, Keyword.get(opts, :subscription_id))
      |> Map.put_new(:raw, raw_subscription)

    {:ok, IngressSubscription.new(attrs)}
  rescue
    exception -> {:error, {:invalid_subscription_result, exception}}
  end

  defp normalize_subscription(_raw_subscription, _bridge_id, _adapter_name, _opts, _default_status),
    do: {:error, :invalid_subscription_result}

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {subscription_key_to_atom(key) || key, value}

      pair ->
        pair
    end)
  end

  defp subscription_key_to_atom("bridge_id"), do: :bridge_id
  defp subscription_key_to_atom("adapter_name"), do: :adapter_name
  defp subscription_key_to_atom("adapter"), do: :adapter_name
  defp subscription_key_to_atom("status"), do: :status
  defp subscription_key_to_atom("external_id"), do: :external_id
  defp subscription_key_to_atom("subscription_id"), do: :subscription_id
  defp subscription_key_to_atom("id"), do: :id
  defp subscription_key_to_atom("target_url"), do: :target_url
  defp subscription_key_to_atom("webhook_url"), do: :target_url
  defp subscription_key_to_atom("expires_at"), do: :expires_at
  defp subscription_key_to_atom("metadata"), do: :metadata
  defp subscription_key_to_atom("raw"), do: :raw
  defp subscription_key_to_atom(_key), do: nil

  defp subscription_error(:unsupported, bridge_id, adapter_name) do
    %{
      type: :ingress_subscription_error,
      code: :unsupported,
      bridge_id: bridge_id,
      adapter_name: adapter_name,
      reason: :unsupported,
      raw: :unsupported
    }
  end

  defp subscription_error(%{type: :adapter_callback_failure, reason: reason} = raw, bridge_id, adapter_name) do
    %{
      type: :ingress_subscription_error,
      code: error_code(reason),
      bridge_id: bridge_id,
      adapter_name: adapter_name,
      reason: reason,
      raw: raw
    }
  end

  defp subscription_error(reason, bridge_id, adapter_name) do
    %{
      type: :ingress_subscription_error,
      code: error_code(reason),
      bridge_id: bridge_id,
      adapter_name: adapter_name,
      reason: reason,
      raw: reason
    }
  end

  defp error_code({:invalid_return, _return}), do: :invalid_adapter_return
  defp error_code(:unsupported), do: :unsupported
  defp error_code({:unsupported, _reason}), do: :unsupported
  defp error_code(_reason), do: :adapter_error

  defp unsupported?(:unsupported), do: true
  defp unsupported?({:unsupported, _reason}), do: true
  defp unsupported?(_reason), do: false

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp maybe_put_new(keyword, _key, nil), do: keyword
  defp maybe_put_new(keyword, key, value), do: Keyword.put_new(keyword, key, value)
end
