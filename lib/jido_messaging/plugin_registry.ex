defmodule JidoMessaging.PluginRegistry do
  @moduledoc """
  Channel plugin discovery and lookup.

  Provides a centralized registry for channel plugins, enabling runtime discovery
  of available channels, their capabilities, and associated adapters.

  ## Usage

  Register plugins at application startup:

      # In your application.ex or a supervisor
      PluginRegistry.register(Plugin.from_channel(JidoMessaging.Channels.Telegram))
      PluginRegistry.register(Plugin.from_channel(JidoMessaging.Channels.Discord))

  Query registered plugins:

      PluginRegistry.list_plugins()
      PluginRegistry.get_plugin(:telegram)
      PluginRegistry.capabilities(:telegram)

  ## Implementation

  Uses an ETS table for storage, which provides fast concurrent reads.
  The table is created on first access and persists for the lifetime of the BEAM.
  """

  alias JidoMessaging.Plugin

  @table_name :jido_messaging_plugin_registry

  @doc """
  Registers a plugin in the registry.

  If a plugin with the same ID already exists, it will be replaced.

  ## Examples

      plugin = Plugin.from_channel(JidoMessaging.Channels.Telegram)
      PluginRegistry.register(plugin)
      # => :ok
  """
  @spec register(Plugin.t()) :: :ok
  def register(%Plugin{} = plugin) do
    ensure_table()
    :ets.insert(@table_name, {plugin.id, plugin})
    :ok
  end

  @doc """
  Unregisters a plugin from the registry.

  ## Examples

      PluginRegistry.unregister(:telegram)
      # => :ok
  """
  @spec unregister(atom()) :: :ok
  def unregister(channel_type) when is_atom(channel_type) do
    ensure_table()
    :ets.delete(@table_name, channel_type)
    :ok
  end

  @doc """
  Lists all registered plugins.

  ## Examples

      PluginRegistry.list_plugins()
      # => [%Plugin{id: :telegram, ...}, %Plugin{id: :discord, ...}]
  """
  @spec list_plugins() :: [Plugin.t()]
  def list_plugins do
    ensure_table()

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_id, plugin} -> plugin end)
  end

  @doc """
  Gets a plugin by its channel type.

  ## Examples

      PluginRegistry.get_plugin(:telegram)
      # => %Plugin{id: :telegram, ...}

      PluginRegistry.get_plugin(:unknown)
      # => nil
  """
  @spec get_plugin(atom()) :: Plugin.t() | nil
  def get_plugin(channel_type) when is_atom(channel_type) do
    ensure_table()

    case :ets.lookup(@table_name, channel_type) do
      [{^channel_type, plugin}] -> plugin
      [] -> nil
    end
  end

  @doc """
  Gets a plugin by its channel type, raising if not found.

  ## Examples

      PluginRegistry.get_plugin!(:telegram)
      # => %Plugin{id: :telegram, ...}

      PluginRegistry.get_plugin!(:unknown)
      # => ** (KeyError) plugin not found: :unknown
  """
  @spec get_plugin!(atom()) :: Plugin.t()
  def get_plugin!(channel_type) when is_atom(channel_type) do
    case get_plugin(channel_type) do
      nil -> raise KeyError, "plugin not found: #{inspect(channel_type)}"
      plugin -> plugin
    end
  end

  @doc """
  Gets capabilities for a channel type.

  Returns an empty list if the channel is not registered.

  ## Examples

      PluginRegistry.capabilities(:telegram)
      # => [:text, :image, :streaming]

      PluginRegistry.capabilities(:unknown)
      # => []
  """
  @spec capabilities(atom()) :: [atom()]
  def capabilities(channel_type) when is_atom(channel_type) do
    case get_plugin(channel_type) do
      nil -> []
      plugin -> plugin.capabilities
    end
  end

  @doc """
  Checks if a channel type supports a specific capability.

  ## Examples

      PluginRegistry.has_capability?(:telegram, :streaming)
      # => true
  """
  @spec has_capability?(atom(), atom()) :: boolean()
  def has_capability?(channel_type, capability)
      when is_atom(channel_type) and is_atom(capability) do
    case get_plugin(channel_type) do
      nil -> false
      plugin -> Plugin.has_capability?(plugin, capability)
    end
  end

  @doc """
  Gets a channel module by its type.

  Returns nil if not registered.

  ## Examples

      PluginRegistry.get_channel_module(:telegram)
      # => JidoMessaging.Channels.Telegram
  """
  @spec get_channel_module(atom()) :: module() | nil
  def get_channel_module(channel_type) when is_atom(channel_type) do
    case get_plugin(channel_type) do
      nil -> nil
      plugin -> plugin.channel_module
    end
  end

  @doc """
  Gets an adapter module for a channel type and adapter kind.

  ## Examples

      PluginRegistry.get_adapter(:telegram, :mentions)
      # => JidoMessaging.Channels.Telegram.Mentions
  """
  @spec get_adapter(atom(), atom()) :: module() | nil
  def get_adapter(channel_type, adapter_type)
      when is_atom(channel_type) and is_atom(adapter_type) do
    case get_plugin(channel_type) do
      nil -> nil
      plugin -> Plugin.get_adapter(plugin, adapter_type)
    end
  end

  @doc """
  Lists all channel types that have been registered.

  ## Examples

      PluginRegistry.list_channel_types()
      # => [:telegram, :discord, :slack]
  """
  @spec list_channel_types() :: [atom()]
  def list_channel_types do
    list_plugins()
    |> Enum.map(& &1.id)
  end

  @doc """
  Clears all registered plugins.

  Primarily useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table_name)
    :ok
  end

  defp ensure_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end
end
