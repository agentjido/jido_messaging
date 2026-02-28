defmodule Jido.Messaging.BridgeRegistry do
  @moduledoc """
  Channel bridge discovery and lookup.

  Provides a centralized registry for channel bridges, enabling runtime discovery
  of available channels, their capabilities, and associated adapters.

  ## Usage

  Register bridges at application startup:

      # In your application.ex or a supervisor
      BridgeRegistry.register(BridgePlugin.from_adapter(MyApp.TelegramAdapter))
      BridgeRegistry.register(BridgePlugin.from_adapter(MyApp.DiscordAdapter))

  Query registered bridges:

      BridgeRegistry.list_bridges()
      BridgeRegistry.get_bridge(:telegram)
      BridgeRegistry.capabilities(:telegram)

  ## Implementation

  Uses an ETS table for storage, which provides fast concurrent reads.
  The table is created on first access and persists for the lifetime of the BEAM.
  """

  require Logger

  alias Jido.Messaging.{AdapterBridge, BridgePlugin}

  @table_name :jido_messaging_bridge_registry
  @supported_manifest_version 1
  @manifest_telemetry_event [:jido_messaging, :bridge_registry, :manifest, :load]
  @bootstrap_telemetry_event [:jido_messaging, :bridge_registry, :bootstrap]
  @collision_policies [:prefer_first, :prefer_last]

  @type manifest_collision_policy :: :prefer_first | :prefer_last

  @type manifest_diagnostic :: %{
          required(:policy) => :fatal_required_bridge_error | :degraded_optional_bridge_error,
          required(:type) => atom(),
          optional(:bridge_id) => atom(),
          optional(:path) => String.t(),
          required(:reason) => term()
        }

  @type collision_diagnostic :: %{
          required(:type) => :bridge_id_collision,
          required(:bridge_id) => atom(),
          required(:policy) => manifest_collision_policy(),
          required(:winning_path) => String.t(),
          required(:discarded_path) => String.t()
        }

  @type bootstrap_result :: %{
          required(:registered_bridge_ids) => [atom()],
          required(:degraded_diagnostics) => [manifest_diagnostic()],
          required(:collision_diagnostics) => [collision_diagnostic()]
        }

  @doc """
  Registers a bridge in the registry.

  If a bridge with the same ID already exists, it will be replaced.

  ## Examples

      bridge = BridgePlugin.from_adapter(MyApp.TelegramAdapter)
      BridgeRegistry.register(bridge)
      # => :ok
  """
  @spec register(BridgePlugin.t()) :: :ok
  def register(%BridgePlugin{} = bridge) do
    ensure_table()
    :ets.insert(@table_name, {bridge.id, bridge})
    :ok
  end

  @doc """
  Loads bridge manifests and registers the resulting bridges with deterministic precedence.

  ## Options

    * `:manifest_paths` - Manifest file paths, wildcard patterns, or directories.
    * `:required_bridges` - Bridge IDs that must load successfully (atoms or strings).
    * `:collision_policy` - `:prefer_first` or `:prefer_last` when bridge IDs collide.
    * `:clear_existing?` - When true, clear the registry before registration.

  Returns `{:error, {:fatal_required_bridge_error, diagnostic}}` for required failures.
  Optional bridge failures degrade with warnings and telemetry.
  """
  @spec bootstrap_from_manifests(keyword()) ::
          {:ok, bootstrap_result()}
          | {:error, {:fatal_required_bridge_error, manifest_diagnostic()}}
  def bootstrap_from_manifests(opts \\ []) do
    manifest_paths =
      opts
      |> Keyword.get(:manifest_paths, [])
      |> List.wrap()
      |> resolve_manifest_paths()

    required_bridges =
      opts
      |> Keyword.get(:required_bridges, [])
      |> List.wrap()

    collision_policy = Keyword.get(opts, :collision_policy, :prefer_last)
    clear_existing? = Keyword.get(opts, :clear_existing?, false)

    with {:ok, required_bridge_set} <- normalize_required_bridges(required_bridges),
         :ok <- validate_collision_policy(collision_policy),
         {:ok, {valid_entries, degraded_diagnostics}} <-
           parse_manifest_entries(manifest_paths, required_bridge_set),
         :ok <- ensure_required_bridges_loaded(valid_entries, required_bridge_set) do
      {selected_entries, collision_diagnostics} = resolve_collisions(valid_entries, collision_policy)

      if clear_existing?, do: clear()

      Enum.each(selected_entries, fn %{bridge: bridge} ->
        register(bridge)
      end)

      result = %{
        registered_bridge_ids: Enum.map(selected_entries, fn %{bridge: bridge} -> bridge.id end),
        degraded_diagnostics: degraded_diagnostics,
        collision_diagnostics: collision_diagnostics
      }

      :telemetry.execute(
        @bootstrap_telemetry_event,
        %{
          manifest_count: length(manifest_paths),
          registered_count: length(result.registered_bridge_ids),
          degraded_count: length(result.degraded_diagnostics),
          collision_count: length(result.collision_diagnostics)
        },
        %{collision_policy: collision_policy}
      )

      {:ok, result}
    else
      {:error, {:fatal_required_bridge_error, diagnostic}} ->
        {:error, {:fatal_required_bridge_error, diagnostic}}

      {:error, reason} ->
        diagnostic = %{
          policy: :fatal_required_bridge_error,
          type: :invalid_bootstrap_config,
          reason: reason
        }

        emit_manifest_telemetry(diagnostic)
        {:error, {:fatal_required_bridge_error, diagnostic}}
    end
  end

  @doc """
  Unregisters a bridge from the registry.

  ## Examples

      BridgeRegistry.unregister(:telegram)
      # => :ok
  """
  @spec unregister(atom()) :: :ok
  def unregister(channel_type) when is_atom(channel_type) do
    ensure_table()
    :ets.delete(@table_name, channel_type)
    :ok
  end

  @doc """
  Lists all registered bridges.

  ## Examples

      BridgeRegistry.list_bridges()
      # => [%BridgePlugin{id: :telegram, ...}, %BridgePlugin{id: :discord, ...}]
  """
  @spec list_bridges() :: [BridgePlugin.t()]
  def list_bridges do
    ensure_table()

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_id, bridge} -> bridge end)
  end

  @doc """
  Gets a bridge by its channel type.

  ## Examples

      BridgeRegistry.get_bridge(:telegram)
      # => %BridgePlugin{id: :telegram, ...}

      BridgeRegistry.get_bridge(:unknown)
      # => nil
  """
  @spec get_bridge(atom()) :: BridgePlugin.t() | nil
  def get_bridge(channel_type) when is_atom(channel_type) do
    ensure_table()

    case :ets.lookup(@table_name, channel_type) do
      [{^channel_type, bridge}] -> bridge
      [] -> nil
    end
  end

  @doc """
  Gets a bridge by its channel type, raising if not found.

  ## Examples

      BridgeRegistry.get_bridge!(:telegram)
      # => %BridgePlugin{id: :telegram, ...}

      BridgeRegistry.get_bridge!(:unknown)
      # => ** (KeyError) bridge not found: :unknown
  """
  @spec get_bridge!(atom()) :: BridgePlugin.t()
  def get_bridge!(channel_type) when is_atom(channel_type) do
    case get_bridge(channel_type) do
      nil -> raise KeyError, "bridge not found: #{inspect(channel_type)}"
      bridge -> bridge
    end
  end

  @doc """
  Gets capabilities for a channel type.

  Returns an empty list if the channel is not registered.

  ## Examples

      BridgeRegistry.capabilities(:telegram)
      # => [:text, :image, :streaming]

      BridgeRegistry.capabilities(:unknown)
      # => []
  """
  @spec capabilities(atom()) :: [atom()]
  def capabilities(channel_type) when is_atom(channel_type) do
    case get_bridge(channel_type) do
      nil -> []
      bridge -> bridge.capabilities
    end
  end

  @doc """
  Checks if a channel type supports a specific capability.

  ## Examples

      BridgeRegistry.has_capability?(:telegram, :streaming)
      # => true
  """
  @spec has_capability?(atom(), atom()) :: boolean()
  def has_capability?(channel_type, capability)
      when is_atom(channel_type) and is_atom(capability) do
    case get_bridge(channel_type) do
      nil -> false
      bridge -> BridgePlugin.has_capability?(bridge, capability)
    end
  end

  @doc """
  Gets a channel module by its type.

  Returns nil if not registered.

  ## Examples

      BridgeRegistry.get_adapter_module(:telegram)
      # => MyApp.TelegramAdapter
  """
  @spec get_adapter_module(atom()) :: module() | nil
  def get_adapter_module(channel_type) when is_atom(channel_type) do
    case get_bridge(channel_type) do
      nil -> nil
      bridge -> bridge.adapter_module
    end
  end

  @doc """
  Gets an adapter module for a channel type and adapter kind.

  ## Examples

      BridgeRegistry.get_adapter(:telegram, :mentions)
      # => MyApp.TelegramMentionsAdapter
  """
  @spec get_adapter(atom(), atom()) :: module() | nil
  def get_adapter(channel_type, adapter_type)
      when is_atom(channel_type) and is_atom(adapter_type) do
    case get_bridge(channel_type) do
      nil -> nil
      bridge -> BridgePlugin.get_adapter(bridge, adapter_type)
    end
  end

  @doc """
  Lists all channel types that have been registered.

  ## Examples

      BridgeRegistry.list_channel_types()
      # => [:telegram, :discord, :slack]
  """
  @spec list_channel_types() :: [atom()]
  def list_channel_types do
    list_bridges()
    |> Enum.map(& &1.id)
  end

  @doc """
  Clears all registered bridges.

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
      heir = Process.whereis(:init)

      try do
        :ets.new(@table_name, [:set, :public, :named_table, {:read_concurrency, true}, {:heir, heir, nil}])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp normalize_required_bridges(required_bridges) do
    Enum.reduce_while(required_bridges, {:ok, MapSet.new()}, fn required_bridge, {:ok, acc} ->
      case to_atom(required_bridge) do
        {:ok, bridge_id} ->
          {:cont, {:ok, MapSet.put(acc, bridge_id)}}

        :error ->
          {:halt, {:error, {:invalid_required_bridge, required_bridge}}}
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

  defp parse_manifest_entries(manifest_paths, required_bridge_set) do
    manifest_paths
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], []}}, fn {manifest_path, index}, {:ok, {valid_entries, degraded}} ->
      case parse_manifest(manifest_path) do
        {:ok, bridge} ->
          emit_manifest_loaded(manifest_path, bridge.id)

          {:cont, {:ok, {[%{bridge: bridge, path: manifest_path, index: index} | valid_entries], degraded}}}

        {:error, diagnostic} ->
          if required_bridge?(diagnostic[:bridge_id], required_bridge_set) do
            fatal =
              diagnostic
              |> Map.put(:policy, :fatal_required_bridge_error)
              |> Map.put_new(:path, manifest_path)

            emit_manifest_telemetry(fatal)
            {:halt, {:error, {:fatal_required_bridge_error, fatal}}}
          else
            degraded_diagnostic =
              diagnostic
              |> Map.put(:policy, :degraded_optional_bridge_error)
              |> Map.put_new(:path, manifest_path)

            Logger.warning(
              "[Jido.Messaging.BridgeRegistry] Optional bridge manifest degraded: #{inspect(degraded_diagnostic)}"
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

  defp ensure_required_bridges_loaded(valid_entries, required_bridge_set) do
    loaded_bridges =
      valid_entries
      |> Enum.map(fn %{bridge: bridge} -> bridge.id end)
      |> MapSet.new()

    missing_required_bridges =
      required_bridge_set
      |> MapSet.difference(loaded_bridges)
      |> Enum.sort()

    case missing_required_bridges do
      [] ->
        :ok

      [missing_bridge | _] ->
        diagnostic = %{
          policy: :fatal_required_bridge_error,
          type: :required_bridge_missing,
          bridge_id: missing_bridge,
          reason: {:required_bridges_missing, missing_required_bridges}
        }

        emit_manifest_telemetry(diagnostic)
        {:error, {:fatal_required_bridge_error, diagnostic}}
    end
  end

  defp resolve_collisions(valid_entries, collision_policy) do
    {winner_map, collisions} =
      Enum.reduce(valid_entries, {%{}, []}, fn entry, {winners, collisions} ->
        bridge_id = entry.bridge.id

        case Map.fetch(winners, bridge_id) do
          :error ->
            {Map.put(winners, bridge_id, entry), collisions}

          {:ok, existing} ->
            {winner, discarded} =
              case collision_policy do
                :prefer_first -> {existing, entry}
                :prefer_last -> {entry, existing}
              end

            collision = %{
              type: :bridge_id_collision,
              bridge_id: bridge_id,
              policy: collision_policy,
              winning_path: winner.path,
              discarded_path: discarded.path
            }

            {Map.put(winners, bridge_id, winner), [collision | collisions]}
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
         {:ok, bridge} <- manifest_to_bridge(decoded_manifest) do
      {:ok, bridge}
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

      {:error, _reason} = error ->
        error
    end
  end

  defp manifest_to_bridge(manifest) do
    with {:ok, id_value} <- fetch_required_field(manifest, :id),
         {:ok, bridge_id} <- to_atom_field(:id, id_value),
         {:ok, adapter_module_value} <-
           fetch_required_field(manifest, :adapter_module) |> tag_bridge_id(bridge_id),
         {:ok, adapter_module} <- to_module_field(:adapter_module, adapter_module_value) |> tag_bridge_id(bridge_id),
         :ok <- ensure_adapter_module(adapter_module) |> tag_bridge_id(bridge_id),
         {:ok, label} <- parse_label(manifest, bridge_id),
         {:ok, capabilities} <- parse_capabilities(manifest, adapter_module) |> tag_bridge_id(bridge_id),
         {:ok, adapters} <- parse_adapters(manifest) |> tag_bridge_id(bridge_id) do
      try do
        {:ok,
         struct!(BridgePlugin, %{
           id: bridge_id,
           adapter_module: adapter_module,
           label: label,
           capabilities: capabilities,
           adapters: adapters
         })}
      rescue
        exception in [ArgumentError, KeyError] ->
          {:error, %{type: :invalid_bridge_definition, bridge_id: bridge_id, reason: Exception.message(exception)}}
      end
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_adapter_module(adapter_module) do
    cond do
      not Code.ensure_loaded?(adapter_module) ->
        {:error, %{type: :unknown_adapter_module, reason: adapter_module}}

      not function_exported?(adapter_module, :transform_incoming, 1) ->
        {:error, %{type: :invalid_adapter_module, reason: {:missing_transform_incoming_callback, adapter_module}}}

      not function_exported?(adapter_module, :send_message, 3) ->
        {:error, %{type: :invalid_adapter_module, reason: {:missing_send_message_callback, adapter_module}}}

      true ->
        :ok
    end
  end

  defp parse_label(manifest, bridge_id) do
    case fetch_optional_field(manifest, :label) do
      :missing ->
        {:ok, humanize_bridge_id(bridge_id)}

      {:ok, label} when is_binary(label) and byte_size(label) > 0 ->
        {:ok, label}

      {:ok, label} ->
        {:error, %{type: :invalid_manifest_schema, bridge_id: bridge_id, reason: {:invalid_label, label}}}
    end
  end

  defp parse_capabilities(manifest, adapter_module) do
    case fetch_optional_field(manifest, :capabilities) do
      :missing ->
        {:ok, AdapterBridge.capabilities(adapter_module)}

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

  defp tag_bridge_id({:error, diagnostic}, bridge_id), do: {:error, Map.put_new(diagnostic, :bridge_id, bridge_id)}
  defp tag_bridge_id(result, _bridge_id), do: result

  defp required_bridge?(nil, _required_bridge_set), do: false
  defp required_bridge?(bridge_id, required_bridge_set), do: MapSet.member?(required_bridge_set, bridge_id)

  defp humanize_bridge_id(bridge_id) do
    bridge_id
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp emit_manifest_loaded(path, bridge_id) do
    :telemetry.execute(
      @manifest_telemetry_event,
      %{count: 1},
      %{policy: :loaded, type: :manifest_loaded, path: path, bridge_id: bridge_id}
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
        bridge_id: Map.get(diagnostic, :bridge_id),
        reason: diagnostic.reason
      }
    )
  end
end
