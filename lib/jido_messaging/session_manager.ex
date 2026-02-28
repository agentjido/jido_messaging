defmodule Jido.Messaging.SessionManager do
  @moduledoc """
  Partitioned route-state manager for deterministic session routing.

  Route state is sharded by session key hash so updates and lookups avoid a
  singleton bottleneck. Each partition enforces TTL and bounded capacity.
  """

  alias Jido.Messaging.SessionManager.Partition

  @default_partition_count max(2, System.schedulers_online() * 2)
  @default_ttl_ms :timer.minutes(30)
  @default_max_entries_per_partition 10_000
  @default_prune_interval_ms :timer.seconds(30)

  @type session_key :: Jido.Messaging.SessionKey.t()
  @type route :: %{
          required(:external_room_id) => term(),
          optional(:channel_type) => atom(),
          optional(:bridge_id) => String.t(),
          optional(:room_id) => String.t() | nil,
          optional(:thread_id) => String.t() | nil,
          optional(atom()) => term()
        }

  @type route_record :: %{
          required(:route) => route(),
          required(:updated_at_ms) => integer(),
          required(:expires_at_ms) => integer()
        }

  @type fallback_reason :: :stale | :miss | :thread_scope_miss | :session_unavailable

  @type resolution :: %{
          required(:external_room_id) => term(),
          required(:route) => route(),
          required(:partition) => non_neg_integer(),
          required(:session_key) => session_key(),
          required(:source) => :state_hit | :partition_fallback | :provided_fallback,
          required(:fallback) => boolean(),
          required(:stale) => boolean(),
          optional(:fallback_reason) => fallback_reason()
        }

  @type prune_result :: %{required(:pruned) => non_neg_integer(), required(:partitions) => pos_integer()}

  @doc """
  Store route state for a session key.
  """
  @spec set(module(), session_key(), route(), keyword()) :: :ok | {:error, term()}
  def set(instance_module, session_key, route, opts \\ [])
      when is_atom(instance_module) and is_tuple(session_key) and is_map(route) and is_list(opts) do
    with :ok <- validate_session_key(session_key),
         :ok <- validate_route(route) do
      partition = route_partition(instance_module, session_key)
      Partition.set(instance_module, partition, session_key, route, opts)
    end
  end

  @doc """
  Fetch fresh route state for a session key.
  """
  @spec get(module(), session_key()) :: {:ok, route_record()} | {:error, :not_found | :expired | :partition_unavailable}
  def get(instance_module, session_key)
      when is_atom(instance_module) and is_tuple(session_key) do
    with :ok <- validate_session_key(session_key) do
      partition = route_partition(instance_module, session_key)
      Partition.get(instance_module, partition, session_key)
    end
  end

  @doc """
  Resolve a route for a session key, using fallbacks when needed.
  """
  @spec resolve(module(), session_key(), [route()] | route()) :: {:ok, resolution()} | {:error, term()}
  def resolve(instance_module, session_key, fallback_routes \\ [])
      when is_atom(instance_module) and is_tuple(session_key) do
    with :ok <- validate_session_key(session_key) do
      partition = route_partition(instance_module, session_key)
      normalized_fallbacks = normalize_fallback_routes(fallback_routes)

      case Partition.resolve(instance_module, partition, session_key, normalized_fallbacks) do
        {:error, :partition_unavailable} ->
          resolve_from_fallback(partition, session_key, normalized_fallbacks)

        other ->
          other
      end
    end
  end

  @doc """
  Trigger pruning across all partitions and return total expired deletions.
  """
  @spec prune(module()) :: prune_result()
  def prune(instance_module) when is_atom(instance_module) do
    partition_count = partition_count(instance_module)

    pruned =
      0..(partition_count - 1)
      |> Enum.reduce(0, fn partition, acc ->
        case Partition.prune(instance_module, partition) do
          {:ok, %{pruned: count}} when is_integer(count) and count >= 0 -> acc + count
          _ -> acc
        end
      end)

    %{pruned: pruned, partitions: partition_count}
  end

  @doc """
  Resolve the partition index for a session key.
  """
  @spec route_partition(module(), session_key()) :: non_neg_integer()
  def route_partition(instance_module, session_key) when is_atom(instance_module) do
    :erlang.phash2(session_key, partition_count(instance_module))
  end

  @doc """
  Return the PID for a partition worker, if running.
  """
  @spec partition_pid(module(), session_key() | non_neg_integer()) :: pid() | nil
  def partition_pid(instance_module, partition) when is_atom(instance_module) and is_integer(partition) do
    Partition.whereis(instance_module, partition)
  end

  def partition_pid(instance_module, session_key) when is_atom(instance_module) and is_tuple(session_key) do
    partition = route_partition(instance_module, session_key)
    partition_pid(instance_module, partition)
  end

  @doc """
  Return configured partition count.
  """
  @spec partition_count(module()) :: pos_integer()
  def partition_count(instance_module) do
    instance_module
    |> config()
    |> Keyword.fetch!(:partition_count)
  end

  @doc """
  Return manager config merged from defaults, global opts, and instance opts.
  """
  @spec config(module()) :: keyword()
  def config(instance_module) when is_atom(instance_module) do
    defaults = [
      partition_count: @default_partition_count,
      ttl_ms: @default_ttl_ms,
      max_entries_per_partition: @default_max_entries_per_partition,
      prune_interval_ms: @default_prune_interval_ms
    ]

    global_opts = Application.get_env(:jido_messaging, :session_manager, [])
    module_opts = Application.get_env(instance_module, :session_manager, [])

    defaults
    |> Keyword.merge(global_opts)
    |> Keyword.merge(module_opts)
    |> sanitize_config()
  end

  defp sanitize_config(config) do
    config
    |> Keyword.update(:partition_count, @default_partition_count, fn value ->
      sanitize_positive_integer(value, @default_partition_count)
    end)
    |> Keyword.update(:ttl_ms, @default_ttl_ms, fn value ->
      sanitize_positive_integer(value, @default_ttl_ms)
    end)
    |> Keyword.update(:max_entries_per_partition, @default_max_entries_per_partition, fn value ->
      sanitize_positive_integer(value, @default_max_entries_per_partition)
    end)
    |> Keyword.update(:prune_interval_ms, @default_prune_interval_ms, fn value ->
      sanitize_positive_integer(value, @default_prune_interval_ms)
    end)
  end

  defp sanitize_positive_integer(value, _default)
       when is_integer(value) and value > 0,
       do: value

  defp sanitize_positive_integer(_value, default), do: default

  defp validate_session_key({channel_type, bridge_id, room_id, thread_id})
       when is_atom(channel_type) and is_binary(bridge_id) and is_binary(room_id) and
              (is_binary(thread_id) or is_nil(thread_id)),
       do: :ok

  defp validate_session_key(_session_key), do: {:error, :invalid_session_key}

  defp validate_route(route) do
    case Map.get(route, :external_room_id) do
      nil -> {:error, :invalid_route}
      _ -> :ok
    end
  end

  defp normalize_fallback_routes(routes) when is_list(routes) do
    routes
    |> Enum.filter(&is_map/1)
    |> Enum.filter(&(Map.get(&1, :external_room_id) != nil))
  end

  defp normalize_fallback_routes(route) when is_map(route), do: normalize_fallback_routes([route])
  defp normalize_fallback_routes(_), do: []

  defp resolve_from_fallback(partition, session_key, [route | _rest]) do
    {:ok,
     %{
       external_room_id: route.external_room_id,
       route: route,
       partition: partition,
       session_key: session_key,
       source: :provided_fallback,
       fallback: true,
       stale: false,
       fallback_reason: :session_unavailable
     }}
  end

  defp resolve_from_fallback(_partition, _session_key, []), do: {:error, :partition_unavailable}
end
