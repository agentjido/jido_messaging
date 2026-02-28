defmodule Jido.Messaging.ConfigStore do
  @moduledoc """
  Runtime-editable bridge and routing control plane.

  This is a single-writer GenServer backed by ETS snapshots for deterministic
  reads and optimistic revision checks.
  """

  use GenServer

  alias Jido.Messaging.{BridgeConfig, RoutingPolicy}

  @bridge_prefix :bridge_config
  @routing_prefix :routing_policy

  @type revision_conflict ::
          {:revision_conflict, expected_revision :: non_neg_integer(), actual_revision :: non_neg_integer() | nil}

  @type state :: %{
          instance_module: module(),
          table: atom()
        }

  @doc "Returns the process name for an instance module."
  @spec name(module()) :: atom()
  def name(instance_module), do: Module.concat(instance_module, ConfigStore)

  @doc "Returns the ETS table name for an instance module."
  @spec table_name(module()) :: atom()
  def table_name(instance_module), do: Module.concat(instance_module, ConfigStoreTable)

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Create or update a bridge config with optimistic revision checks."
  @spec put_bridge_config(module() | pid(), BridgeConfig.t() | map()) ::
          {:ok, BridgeConfig.t()} | {:error, revision_conflict() | term()}
  def put_bridge_config(instance_module, attrs) when is_atom(instance_module) and is_map(attrs) do
    GenServer.call(name(instance_module), {:put_bridge_config, attrs})
  end

  def put_bridge_config(pid, attrs) when is_pid(pid) and is_map(attrs) do
    GenServer.call(pid, {:put_bridge_config, attrs})
  end

  @doc "Fetch a bridge config by id."
  @spec get_bridge_config(module() | pid(), String.t()) :: {:ok, BridgeConfig.t()} | {:error, :not_found}
  def get_bridge_config(instance_module, bridge_id) when is_atom(instance_module) and is_binary(bridge_id) do
    GenServer.call(name(instance_module), {:get_bridge_config, bridge_id})
  end

  def get_bridge_config(pid, bridge_id) when is_pid(pid) and is_binary(bridge_id) do
    GenServer.call(pid, {:get_bridge_config, bridge_id})
  end

  @doc "List bridge configs, optionally filtered by `enabled: true | false`."
  @spec list_bridge_configs(module() | pid(), keyword()) :: [BridgeConfig.t()]
  def list_bridge_configs(instance_or_pid, opts \\ [])

  def list_bridge_configs(instance_module, opts) when is_atom(instance_module) and is_list(opts) do
    GenServer.call(name(instance_module), {:list_bridge_configs, opts})
  end

  def list_bridge_configs(pid, opts) when is_pid(pid) and is_list(opts) do
    GenServer.call(pid, {:list_bridge_configs, opts})
  end

  @doc "Delete a bridge config."
  @spec delete_bridge_config(module() | pid(), String.t()) :: :ok | {:error, :not_found}
  def delete_bridge_config(instance_module, bridge_id) when is_atom(instance_module) and is_binary(bridge_id) do
    GenServer.call(name(instance_module), {:delete_bridge_config, bridge_id})
  end

  def delete_bridge_config(pid, bridge_id) when is_pid(pid) and is_binary(bridge_id) do
    GenServer.call(pid, {:delete_bridge_config, bridge_id})
  end

  @doc "Create or update room routing policy with optimistic revision checks."
  @spec put_routing_policy(module() | pid(), String.t(), RoutingPolicy.t() | map()) ::
          {:ok, RoutingPolicy.t()} | {:error, revision_conflict() | term()}
  def put_routing_policy(instance_module, room_id, attrs)
      when is_atom(instance_module) and is_binary(room_id) and is_map(attrs) do
    GenServer.call(name(instance_module), {:put_routing_policy, room_id, attrs})
  end

  def put_routing_policy(pid, room_id, attrs) when is_pid(pid) and is_binary(room_id) and is_map(attrs) do
    GenServer.call(pid, {:put_routing_policy, room_id, attrs})
  end

  @doc "Fetch room routing policy."
  @spec get_routing_policy(module() | pid(), String.t()) :: {:ok, RoutingPolicy.t()} | {:error, :not_found}
  def get_routing_policy(instance_module, room_id) when is_atom(instance_module) and is_binary(room_id) do
    GenServer.call(name(instance_module), {:get_routing_policy, room_id})
  end

  def get_routing_policy(pid, room_id) when is_pid(pid) and is_binary(room_id) do
    GenServer.call(pid, {:get_routing_policy, room_id})
  end

  @doc "Delete room routing policy."
  @spec delete_routing_policy(module() | pid(), String.t()) :: :ok | {:error, :not_found}
  def delete_routing_policy(instance_module, room_id) when is_atom(instance_module) and is_binary(room_id) do
    GenServer.call(name(instance_module), {:delete_routing_policy, room_id})
  end

  def delete_routing_policy(pid, room_id) when is_pid(pid) and is_binary(room_id) do
    GenServer.call(pid, {:delete_routing_policy, room_id})
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    table_name = Keyword.get(opts, :table_name, table_name(instance_module))

    table =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:set, :named_table, :protected, {:read_concurrency, true}])

        _tid ->
          :ets.delete_all_objects(table_name)
          table_name
      end

    {:ok, %{instance_module: instance_module, table: table}}
  end

  @impl true
  def handle_call({:put_bridge_config, attrs}, _from, state) do
    attrs = normalize_map(attrs)
    id = map_get(attrs, :id)
    existing = lookup_bridge(state.table, id)
    expected_revision = map_get(attrs, :revision)

    with :ok <- validate_revision(expected_revision, existing),
         {:ok, config} <- normalize_bridge_config(attrs, existing) do
      :ets.insert(state.table, {bridge_key(config.id), config})
      :ok = reconcile_bridges(state.instance_module)
      {:reply, {:ok, config}, state}
    else
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get_bridge_config, bridge_id}, _from, state) do
    reply =
      case lookup_bridge(state.table, bridge_id) do
        nil -> {:error, :not_found}
        config -> {:ok, config}
      end

    {:reply, reply, state}
  end

  def handle_call({:list_bridge_configs, opts}, _from, state) do
    enabled_filter = Keyword.get(opts, :enabled)

    configs =
      state.table
      |> list_entries(@bridge_prefix)
      |> maybe_filter_enabled(enabled_filter)
      |> Enum.sort_by(& &1.id)

    {:reply, configs, state}
  end

  def handle_call({:delete_bridge_config, bridge_id}, _from, state) do
    reply =
      case :ets.take(state.table, bridge_key(bridge_id)) do
        [] ->
          {:error, :not_found}

        _ ->
          :ok = reconcile_bridges(state.instance_module)
          :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:put_routing_policy, room_id, attrs}, _from, state) do
    attrs = attrs |> normalize_map() |> Map.put(:room_id, room_id)
    existing = lookup_routing_policy(state.table, room_id)
    expected_revision = map_get(attrs, :revision)

    with :ok <- validate_revision(expected_revision, existing),
         {:ok, policy} <- normalize_routing_policy(attrs, existing) do
      :ets.insert(state.table, {routing_key(room_id), policy})
      {:reply, {:ok, policy}, state}
    else
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get_routing_policy, room_id}, _from, state) do
    reply =
      case lookup_routing_policy(state.table, room_id) do
        nil -> {:error, :not_found}
        policy -> {:ok, policy}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_routing_policy, room_id}, _from, state) do
    reply =
      case :ets.take(state.table, routing_key(room_id)) do
        [] -> {:error, :not_found}
        _ -> :ok
      end

    {:reply, reply, state}
  end

  defp list_entries(table, prefix) do
    table
    |> :ets.match_object({{prefix, :_}, :_})
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp maybe_filter_enabled(configs, nil), do: configs
  defp maybe_filter_enabled(configs, value), do: Enum.filter(configs, &(&1.enabled == value))

  defp normalize_bridge_config(attrs, existing) do
    merged =
      existing
      |> maybe_struct_to_map()
      |> Map.merge(attrs)
      |> Map.put_new(:id, map_get(attrs, :id) || (existing && existing.id))

    adapter_module = map_get(merged, :adapter_module)

    if is_atom(adapter_module) do
      now = DateTime.utc_now()
      inserted_at = if existing, do: existing.inserted_at, else: now

      config =
        BridgeConfig.new(
          merged
          |> Map.put(:adapter_module, adapter_module)
          |> Map.put(:revision, next_revision(existing))
          |> Map.put(:inserted_at, inserted_at)
          |> Map.put(:updated_at, now)
          |> Map.put_new(:capabilities, Jido.Chat.Adapter.capabilities(adapter_module))
        )

      {:ok, config}
    else
      {:error, :invalid_adapter_module}
    end
  end

  defp normalize_routing_policy(attrs, existing) do
    merged =
      existing
      |> maybe_struct_to_map()
      |> Map.merge(attrs)
      |> Map.put_new(:room_id, map_get(attrs, :room_id) || (existing && existing.room_id))

    room_id = map_get(merged, :room_id)

    if is_binary(room_id) and room_id != "" do
      now = DateTime.utc_now()
      inserted_at = if existing, do: existing.inserted_at, else: now

      policy =
        RoutingPolicy.new(
          merged
          |> Map.put(:id, room_id)
          |> Map.put(:room_id, room_id)
          |> Map.put(:revision, next_revision(existing))
          |> Map.put(:inserted_at, inserted_at)
          |> Map.put(:updated_at, now)
        )

      {:ok, policy}
    else
      {:error, :invalid_room_id}
    end
  end

  defp validate_revision(nil, _existing), do: :ok

  defp validate_revision(expected_revision, nil) when is_integer(expected_revision) do
    if expected_revision in [0, -1] do
      :ok
    else
      {:error, {:revision_conflict, expected_revision, nil}}
    end
  end

  defp validate_revision(expected_revision, %{revision: actual_revision})
       when is_integer(expected_revision) and is_integer(actual_revision) do
    if expected_revision == actual_revision do
      :ok
    else
      {:error, {:revision_conflict, expected_revision, actual_revision}}
    end
  end

  defp validate_revision(_expected_revision, _existing), do: {:error, :invalid_revision}

  defp next_revision(nil), do: 1
  defp next_revision(%{revision: revision}) when is_integer(revision), do: revision + 1
  defp next_revision(_), do: 1

  defp lookup_bridge(_table, nil), do: nil

  defp lookup_bridge(table, bridge_id) do
    case :ets.lookup(table, bridge_key(bridge_id)) do
      [{_, config}] -> config
      [] -> nil
    end
  end

  defp lookup_routing_policy(table, room_id) do
    case :ets.lookup(table, routing_key(room_id)) do
      [{_, policy}] -> policy
      [] -> nil
    end
  end

  defp bridge_key(bridge_id), do: {@bridge_prefix, bridge_id}
  defp routing_key(room_id), do: {@routing_prefix, room_id}

  defp normalize_map(%_{} = struct), do: struct |> Map.from_struct() |> normalize_map()

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case key_to_atom(key) do
          nil -> acc
          atom -> Map.put(acc, atom, value)
        end

      {_key, _value}, acc ->
        acc
    end)
  end

  defp maybe_struct_to_map(nil), do: %{}
  defp maybe_struct_to_map(%_{} = struct), do: Map.from_struct(struct)
  defp maybe_struct_to_map(map) when is_map(map), do: map

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp key_to_atom("id"), do: :id
  defp key_to_atom("room_id"), do: :room_id
  defp key_to_atom("adapter_module"), do: :adapter_module
  defp key_to_atom("adapter"), do: :adapter_module
  defp key_to_atom("credentials"), do: :credentials
  defp key_to_atom("opts"), do: :opts
  defp key_to_atom("enabled"), do: :enabled
  defp key_to_atom("capabilities"), do: :capabilities
  defp key_to_atom("revision"), do: :revision
  defp key_to_atom("delivery_mode"), do: :delivery_mode
  defp key_to_atom("failover_policy"), do: :failover_policy
  defp key_to_atom("dedupe_scope"), do: :dedupe_scope
  defp key_to_atom("fallback_order"), do: :fallback_order
  defp key_to_atom("metadata"), do: :metadata
  defp key_to_atom("inserted_at"), do: :inserted_at
  defp key_to_atom("updated_at"), do: :updated_at
  defp key_to_atom(_), do: nil

  defp reconcile_bridges(instance_module) do
    if Code.ensure_loaded?(Jido.Messaging.BridgeSupervisor) do
      _ =
        spawn(fn ->
          _ = Jido.Messaging.BridgeSupervisor.reconcile(instance_module)
          :ok
        end)
    end

    :ok
  end
end
