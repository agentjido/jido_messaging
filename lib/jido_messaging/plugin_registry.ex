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

  require Logger

  alias JidoMessaging.{Channel, Plugin}

  @table_name :jido_messaging_plugin_registry
  @supported_manifest_version 1
  @manifest_telemetry_event [:jido_messaging, :plugin_registry, :manifest, :load]
  @bootstrap_telemetry_event [:jido_messaging, :plugin_registry, :bootstrap]
  @collision_policies [:prefer_first, :prefer_last]

  @type manifest_collision_policy :: :prefer_first | :prefer_last

  @type manifest_diagnostic :: %{
          required(:policy) => :fatal_required_plugin_error | :degraded_optional_plugin_error,
          required(:type) => atom(),
          optional(:plugin_id) => atom(),
          optional(:path) => String.t(),
          required(:reason) => term()
        }

  @type collision_diagnostic :: %{
          required(:type) => :plugin_id_collision,
          required(:plugin_id) => atom(),
          required(:policy) => manifest_collision_policy(),
          required(:winning_path) => String.t(),
          required(:discarded_path) => String.t()
        }

  @type bootstrap_result :: %{
          required(:registered_plugin_ids) => [atom()],
          required(:degraded_diagnostics) => [manifest_diagnostic()],
          required(:collision_diagnostics) => [collision_diagnostic()]
        }

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
  Loads plugin manifests and registers the resulting plugins with deterministic precedence.

  ## Options

    * `:manifest_paths` - Manifest file paths, wildcard patterns, or directories.
    * `:required_plugins` - Plugin IDs that must load successfully (atoms or strings).
    * `:collision_policy` - `:prefer_first` or `:prefer_last` when plugin IDs collide.
    * `:clear_existing?` - When true, clear the registry before registration.

  Returns `{:error, {:fatal_required_plugin_error, diagnostic}}` for required failures.
  Optional plugin failures degrade with warnings and telemetry.
  """
  @spec bootstrap_from_manifests(keyword()) ::
          {:ok, bootstrap_result()}
          | {:error, {:fatal_required_plugin_error, manifest_diagnostic()}}
  def bootstrap_from_manifests(opts \\ []) do
    manifest_paths =
      opts
      |> Keyword.get(:manifest_paths, [])
      |> List.wrap()
      |> resolve_manifest_paths()

    required_plugins =
      opts
      |> Keyword.get(:required_plugins, [])
      |> List.wrap()

    collision_policy = Keyword.get(opts, :collision_policy, :prefer_last)
    clear_existing? = Keyword.get(opts, :clear_existing?, false)

    with {:ok, required_plugin_set} <- normalize_required_plugins(required_plugins),
         :ok <- validate_collision_policy(collision_policy),
         {:ok, {valid_entries, degraded_diagnostics}} <-
           parse_manifest_entries(manifest_paths, required_plugin_set),
         :ok <- ensure_required_plugins_loaded(valid_entries, required_plugin_set) do
      {selected_entries, collision_diagnostics} = resolve_collisions(valid_entries, collision_policy)

      if clear_existing?, do: clear()

      Enum.each(selected_entries, fn %{plugin: plugin} ->
        register(plugin)
      end)

      result = %{
        registered_plugin_ids: Enum.map(selected_entries, fn %{plugin: plugin} -> plugin.id end),
        degraded_diagnostics: degraded_diagnostics,
        collision_diagnostics: collision_diagnostics
      }

      :telemetry.execute(
        @bootstrap_telemetry_event,
        %{
          manifest_count: length(manifest_paths),
          registered_count: length(result.registered_plugin_ids),
          degraded_count: length(result.degraded_diagnostics),
          collision_count: length(result.collision_diagnostics)
        },
        %{collision_policy: collision_policy}
      )

      {:ok, result}
    else
      {:error, {:fatal_required_plugin_error, diagnostic}} ->
        {:error, {:fatal_required_plugin_error, diagnostic}}

      {:error, reason} ->
        diagnostic = %{
          policy: :fatal_required_plugin_error,
          type: :invalid_bootstrap_config,
          reason: reason
        }

        emit_manifest_telemetry(diagnostic)
        {:error, {:fatal_required_plugin_error, diagnostic}}
    end
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

  defp normalize_required_plugins(required_plugins) do
    Enum.reduce_while(required_plugins, {:ok, MapSet.new()}, fn required_plugin, {:ok, acc} ->
      case to_atom(required_plugin) do
        {:ok, plugin_id} ->
          {:cont, {:ok, MapSet.put(acc, plugin_id)}}

        :error ->
          {:halt, {:error, {:invalid_required_plugin, required_plugin}}}
      end
    end)
  end

  defp validate_collision_policy(policy) when policy in @collision_policies, do: :ok
  defp validate_collision_policy(policy), do: {:error, {:invalid_collision_policy, policy}}

  defp resolve_manifest_paths(paths) do
    paths
    |> Enum.flat_map(&expand_manifest_path/1)
    |> Enum.uniq()
  end

  defp expand_manifest_path(path) when is_binary(path) do
    cond do
      File.dir?(path) ->
        path
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.sort()

      wildcard_path?(path) ->
        path
        |> Path.wildcard()
        |> Enum.sort()

      true ->
        [path]
    end
  end

  defp expand_manifest_path(path), do: [to_string(path)]

  defp wildcard_path?(path) do
    String.contains?(path, ["*", "?", "["])
  end

  defp parse_manifest_entries(manifest_paths, required_plugin_set) do
    manifest_paths
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], []}}, fn {manifest_path, index}, {:ok, {valid_entries, degraded}} ->
      case parse_manifest(manifest_path) do
        {:ok, plugin} ->
          emit_manifest_loaded(manifest_path, plugin.id)

          {:cont, {:ok, {[%{plugin: plugin, path: manifest_path, index: index} | valid_entries], degraded}}}

        {:error, diagnostic} ->
          if required_plugin?(diagnostic[:plugin_id], required_plugin_set) do
            fatal =
              diagnostic
              |> Map.put(:policy, :fatal_required_plugin_error)
              |> Map.put_new(:path, manifest_path)

            emit_manifest_telemetry(fatal)
            {:halt, {:error, {:fatal_required_plugin_error, fatal}}}
          else
            degraded_diagnostic =
              diagnostic
              |> Map.put(:policy, :degraded_optional_plugin_error)
              |> Map.put_new(:path, manifest_path)

            Logger.warning(
              "[JidoMessaging.PluginRegistry] Optional plugin manifest degraded: #{inspect(degraded_diagnostic)}"
            )

            emit_manifest_telemetry(degraded_diagnostic)
            {:cont, {:ok, {valid_entries, [degraded_diagnostic | degraded]}}}
          end
      end
    end)
    |> case do
      {:ok, {valid_entries, degraded}} ->
        {:ok, {Enum.reverse(valid_entries), Enum.reverse(degraded)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_required_plugins_loaded(valid_entries, required_plugin_set) do
    loaded_plugins =
      valid_entries
      |> Enum.map(fn %{plugin: plugin} -> plugin.id end)
      |> MapSet.new()

    missing_required_plugins =
      required_plugin_set
      |> MapSet.difference(loaded_plugins)
      |> Enum.sort()

    case missing_required_plugins do
      [] ->
        :ok

      [missing_plugin | _] ->
        diagnostic = %{
          policy: :fatal_required_plugin_error,
          type: :required_plugin_missing,
          plugin_id: missing_plugin,
          reason: {:required_plugins_missing, missing_required_plugins}
        }

        emit_manifest_telemetry(diagnostic)
        {:error, {:fatal_required_plugin_error, diagnostic}}
    end
  end

  defp resolve_collisions(valid_entries, collision_policy) do
    {winner_map, collisions} =
      Enum.reduce(valid_entries, {%{}, []}, fn entry, {winners, collisions} ->
        plugin_id = entry.plugin.id

        case Map.fetch(winners, plugin_id) do
          :error ->
            {Map.put(winners, plugin_id, entry), collisions}

          {:ok, existing} ->
            {winner, discarded} =
              case collision_policy do
                :prefer_first -> {existing, entry}
                :prefer_last -> {entry, existing}
              end

            collision = %{
              type: :plugin_id_collision,
              plugin_id: plugin_id,
              policy: collision_policy,
              winning_path: winner.path,
              discarded_path: discarded.path
            }

            {Map.put(winners, plugin_id, winner), [collision | collisions]}
        end
      end)

    selected_entries =
      winner_map
      |> Map.values()
      |> Enum.sort_by(& &1.index)

    {selected_entries, Enum.reverse(collisions)}
  end

  defp parse_manifest(path) do
    with {:ok, manifest_body} <- read_manifest(path),
         {:ok, decoded_manifest} <- decode_manifest(manifest_body),
         :ok <- validate_manifest_version(decoded_manifest),
         {:ok, plugin} <- manifest_to_plugin(decoded_manifest) do
      {:ok, plugin}
    else
      {:error, diagnostic} ->
        {:error, Map.put_new(diagnostic, :path, path)}
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, manifest_body} ->
        {:ok, manifest_body}

      {:error, reason} ->
        {:error, %{type: :manifest_read_error, reason: reason}}
    end
  end

  defp decode_manifest(manifest_body) do
    case Jason.decode(manifest_body) do
      {:ok, manifest} when is_map(manifest) ->
        {:ok, manifest}

      {:ok, other} ->
        {:error, %{type: :invalid_manifest_schema, reason: {:expected_object, other}}}

      {:error, reason} ->
        {:error, %{type: :invalid_manifest_json, reason: reason}}
    end
  end

  defp validate_manifest_version(manifest) do
    with {:ok, manifest_version} <- fetch_required_field(manifest, :manifest_version),
         true <- manifest_version == @supported_manifest_version do
      :ok
    else
      false ->
        {:error,
         %{
           type: :unsupported_manifest_version,
           reason: {:expected_version, @supported_manifest_version}
         }}

      {:ok, manifest_version} ->
        {:error,
         %{
           type: :unsupported_manifest_version,
           reason: {:unsupported_manifest_version, manifest_version}
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp manifest_to_plugin(manifest) do
    with {:ok, id_value} <- fetch_required_field(manifest, :id),
         {:ok, plugin_id} <- to_atom_field(:id, id_value),
         {:ok, channel_module_value} <-
           fetch_required_field(manifest, :channel_module) |> tag_plugin_id(plugin_id),
         {:ok, channel_module} <- to_module_field(:channel_module, channel_module_value) |> tag_plugin_id(plugin_id),
         :ok <- ensure_channel_module(channel_module) |> tag_plugin_id(plugin_id),
         {:ok, label} <- parse_label(manifest, plugin_id),
         {:ok, capabilities} <- parse_capabilities(manifest, channel_module) |> tag_plugin_id(plugin_id),
         {:ok, adapters} <- parse_adapters(manifest) |> tag_plugin_id(plugin_id) do
      try do
        {:ok,
         struct!(Plugin, %{
           id: plugin_id,
           channel_module: channel_module,
           label: label,
           capabilities: capabilities,
           adapters: adapters
         })}
      rescue
        exception in [ArgumentError, KeyError] ->
          {:error, %{type: :invalid_plugin_definition, plugin_id: plugin_id, reason: Exception.message(exception)}}
      end
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_channel_module(channel_module) do
    cond do
      not Code.ensure_loaded?(channel_module) ->
        {:error, %{type: :unknown_channel_module, reason: channel_module}}

      not function_exported?(channel_module, :channel_type, 0) ->
        {:error, %{type: :invalid_channel_module, reason: {:missing_channel_type_callback, channel_module}}}

      true ->
        :ok
    end
  end

  defp parse_label(manifest, plugin_id) do
    case fetch_optional_field(manifest, :label) do
      :missing ->
        {:ok, humanize_plugin_id(plugin_id)}

      {:ok, label} when is_binary(label) and byte_size(label) > 0 ->
        {:ok, label}

      {:ok, label} ->
        {:error, %{type: :invalid_manifest_schema, plugin_id: plugin_id, reason: {:invalid_label, label}}}
    end
  end

  defp parse_capabilities(manifest, channel_module) do
    case fetch_optional_field(manifest, :capabilities) do
      :missing ->
        {:ok, Channel.capabilities(channel_module)}

      {:ok, capabilities} when is_list(capabilities) ->
        capabilities
        |> Enum.reduce_while({:ok, []}, fn capability, {:ok, acc} ->
          case to_atom(capability) do
            {:ok, capability_atom} -> {:cont, {:ok, [capability_atom | acc]}}
            :error -> {:halt, {:error, %{type: :invalid_manifest_schema, reason: {:invalid_capability, capability}}}}
          end
        end)
        |> case do
          {:ok, capability_atoms} -> {:ok, capability_atoms |> Enum.reverse() |> Enum.uniq()}
          {:error, _reason} = error -> error
        end

      {:ok, capabilities} ->
        {:error, %{type: :invalid_manifest_schema, reason: {:invalid_capabilities, capabilities}}}
    end
  end

  defp parse_adapters(manifest) do
    case fetch_optional_field(manifest, :adapters) do
      :missing ->
        {:ok, %{}}

      {:ok, adapters} when is_map(adapters) ->
        Enum.reduce_while(adapters, {:ok, %{}}, fn {adapter_key, adapter_module}, {:ok, acc} ->
          with {:ok, adapter_key_atom} <- to_atom_field(:adapter, adapter_key),
               {:ok, adapter_module_atom} <- to_module_field(:adapter_module, adapter_module) do
            {:cont, {:ok, Map.put(acc, adapter_key_atom, adapter_module_atom)}}
          else
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:ok, adapters} ->
        {:error, %{type: :invalid_manifest_schema, reason: {:invalid_adapters, adapters}}}
    end
  end

  defp fetch_required_field(manifest, field) do
    case fetch_optional_field(manifest, field) do
      :missing -> {:error, %{type: :invalid_manifest_schema, reason: {:missing_required_field, field}}}
      {:ok, value} -> {:ok, value}
    end
  end

  defp fetch_optional_field(manifest, field) when is_map(manifest) do
    case Map.fetch(manifest, Atom.to_string(field)) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(manifest, field) do
          {:ok, value} -> {:ok, value}
          :error -> :missing
        end
    end
  end

  defp to_atom_field(field, value) do
    case to_atom(value) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error, %{type: :invalid_manifest_schema, reason: {:invalid_atom_field, field, value}}}
    end
  end

  defp to_atom(value) when is_atom(value), do: {:ok, value}
  defp to_atom(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, String.to_atom(value)}
  defp to_atom(_value), do: :error

  defp to_module_field(field, value) do
    case to_module(value) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, %{type: :invalid_manifest_schema, reason: {:invalid_module_field, field, value}}}
    end
  end

  defp to_module(module) when is_atom(module), do: {:ok, module}

  defp to_module(module) when is_binary(module) and byte_size(module) > 0 do
    module
    |> String.split(".")
    |> Module.concat()
    |> then(&{:ok, &1})
  end

  defp to_module(_module), do: :error

  defp tag_plugin_id({:error, diagnostic}, plugin_id), do: {:error, Map.put_new(diagnostic, :plugin_id, plugin_id)}
  defp tag_plugin_id(result, _plugin_id), do: result

  defp required_plugin?(nil, _required_plugin_set), do: false
  defp required_plugin?(plugin_id, required_plugin_set), do: MapSet.member?(required_plugin_set, plugin_id)

  defp humanize_plugin_id(plugin_id) do
    plugin_id
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp emit_manifest_loaded(path, plugin_id) do
    :telemetry.execute(
      @manifest_telemetry_event,
      %{count: 1},
      %{policy: :loaded, type: :manifest_loaded, path: path, plugin_id: plugin_id}
    )
  end

  defp emit_manifest_telemetry(diagnostic) do
    :telemetry.execute(
      @manifest_telemetry_event,
      %{count: 1},
      %{
        policy: diagnostic.policy,
        type: diagnostic.type,
        path: Map.get(diagnostic, :path),
        plugin_id: Map.get(diagnostic, :plugin_id),
        reason: diagnostic.reason
      }
    )
  end
end
