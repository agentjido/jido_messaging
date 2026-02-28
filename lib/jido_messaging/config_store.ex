defmodule Jido.Messaging.ConfigStore do
  @moduledoc """
  Runtime-editable bridge and routing control plane.

  This is a single-writer GenServer that persists control-plane state through
  the configured `Jido.Messaging.Persistence` backend.
  """

  use GenServer

  alias Jido.Messaging.{BridgeConfig, RoutingPolicy, Runtime}

  @type revision_conflict ::
          {:revision_conflict, expected_revision :: non_neg_integer(), actual_revision :: non_neg_integer() | nil}

  @type state :: %{
          instance_module: module()
        }

  @doc "Returns the process name for an instance module."
  @spec name(module()) :: atom()
  def name(instance_module), do: Module.concat(instance_module, ConfigStore)

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
    {:ok, %{instance_module: instance_module}}
  end

  @impl true
  def handle_call({:put_bridge_config, attrs}, _from, state) do
    attrs = normalize_map(attrs)
    id = map_get(attrs, :id)

    {persistence, persistence_state} = runtime_persistence(state.instance_module)
    existing = get_existing_bridge(persistence, persistence_state, id)
    expected_revision = map_get(attrs, :revision)

    reply =
      with :ok <- validate_revision(expected_revision, existing),
           {:ok, config} <- normalize_bridge_config(attrs, existing),
           {:ok, _saved} <- persistence.save_bridge_config(persistence_state, config) do
        trigger_reconcile(state.instance_module)
        {:ok, config}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_bridge_config, bridge_id}, _from, state) do
    {persistence, persistence_state} = runtime_persistence(state.instance_module)
    {:reply, persistence.get_bridge_config(persistence_state, bridge_id), state}
  end

  def handle_call({:list_bridge_configs, opts}, _from, state) do
    {persistence, persistence_state} = runtime_persistence(state.instance_module)

    reply =
      case persistence.list_bridge_configs(persistence_state, opts) do
        {:ok, configs} -> configs
        {:error, _reason} -> []
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_bridge_config, bridge_id}, _from, state) do
    {persistence, persistence_state} = runtime_persistence(state.instance_module)

    reply =
      case persistence.delete_bridge_config(persistence_state, bridge_id) do
        :ok ->
          trigger_reconcile(state.instance_module)
          :ok

        {:error, _reason} = error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call({:put_routing_policy, room_id, attrs}, _from, state) do
    attrs = attrs |> normalize_map() |> Map.put(:room_id, room_id)
    {persistence, persistence_state} = runtime_persistence(state.instance_module)
    existing = get_existing_routing_policy(persistence, persistence_state, room_id)
    expected_revision = map_get(attrs, :revision)

    reply =
      with :ok <- validate_revision(expected_revision, existing),
           {:ok, policy} <- normalize_routing_policy(attrs, existing),
           {:ok, _saved} <- persistence.save_routing_policy(persistence_state, policy) do
        {:ok, policy}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_routing_policy, room_id}, _from, state) do
    {persistence, persistence_state} = runtime_persistence(state.instance_module)
    {:reply, persistence.get_routing_policy(persistence_state, room_id), state}
  end

  def handle_call({:delete_routing_policy, room_id}, _from, state) do
    {persistence, persistence_state} = runtime_persistence(state.instance_module)
    {:reply, persistence.delete_routing_policy(persistence_state, room_id), state}
  end

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

  defp runtime_persistence(instance_module) do
    runtime = Module.concat(instance_module, :Runtime)
    Runtime.get_persistence(runtime)
  end

  defp get_existing_bridge(_persistence, _state, nil), do: nil

  defp get_existing_bridge(persistence, persistence_state, bridge_id) do
    case persistence.get_bridge_config(persistence_state, bridge_id) do
      {:ok, config} -> config
      {:error, :not_found} -> nil
    end
  end

  defp get_existing_routing_policy(persistence, persistence_state, room_id) do
    case persistence.get_routing_policy(persistence_state, room_id) do
      {:ok, policy} -> policy
      {:error, :not_found} -> nil
    end
  end

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
  defp key_to_atom("inserted_at"), do: :inserted_at
  defp key_to_atom("updated_at"), do: :updated_at
  defp key_to_atom("delivery_policy"), do: :delivery_policy
  defp key_to_atom("adapter_key"), do: :adapter_key
  defp key_to_atom("mode"), do: :mode
  defp key_to_atom("outbound"), do: :outbound
  defp key_to_atom("default"), do: :default
  defp key_to_atom(_), do: nil

  defp reconcile_bridges(instance_module) do
    bridge_supervisor = Module.concat(instance_module, :BridgeSupervisor)

    case Process.whereis(bridge_supervisor) do
      nil -> :ok
      _pid -> Jido.Messaging.BridgeSupervisor.reconcile(instance_module)
    end
  end

  defp trigger_reconcile(instance_module) do
    _ =
      Task.start(fn ->
        reconcile_bridges(instance_module)
      end)

    :ok
  end
end
