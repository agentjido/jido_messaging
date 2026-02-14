defmodule JidoMessaging.SessionManager.Partition do
  @moduledoc false
  use GenServer

  alias JidoMessaging.SessionManager

  @default_call_timeout 5_000

  @type state :: %{
          instance_module: module(),
          partition: non_neg_integer(),
          table: :ets.tid(),
          ttl_ms: pos_integer(),
          max_entries_per_partition: pos_integer(),
          prune_interval_ms: pos_integer(),
          order: :queue.queue(),
          next_seq: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    partition = Keyword.fetch!(opts, :partition)
    name = via_tuple(instance_module, partition)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec whereis(module(), non_neg_integer()) :: pid() | nil
  def whereis(instance_module, partition) do
    registry = registry_name(instance_module)

    case Registry.lookup(registry, {:session_manager_partition, partition}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec set(module(), non_neg_integer(), SessionManager.session_key(), SessionManager.route(), keyword(), timeout()) ::
          :ok | {:error, :partition_unavailable}
  def set(instance_module, partition, session_key, route, opts \\ [], timeout \\ @default_call_timeout) do
    with_pid(instance_module, partition, fn pid ->
      GenServer.call(pid, {:set, session_key, route, opts}, timeout)
    end)
  end

  @spec get(module(), non_neg_integer(), SessionManager.session_key(), timeout()) ::
          {:ok, SessionManager.route_record()} | {:error, :not_found | :expired | :partition_unavailable}
  def get(instance_module, partition, session_key, timeout \\ @default_call_timeout) do
    with_pid(instance_module, partition, fn pid ->
      GenServer.call(pid, {:get, session_key}, timeout)
    end)
  end

  @spec resolve(module(), non_neg_integer(), SessionManager.session_key(), [SessionManager.route()], timeout()) ::
          {:ok, SessionManager.resolution()} | {:error, :no_route | :partition_unavailable}
  def resolve(instance_module, partition, session_key, fallback_routes, timeout \\ @default_call_timeout) do
    with_pid(instance_module, partition, fn pid ->
      GenServer.call(pid, {:resolve, session_key, fallback_routes}, timeout)
    end)
  end

  @spec prune(module(), non_neg_integer(), timeout()) ::
          {:ok, %{required(:pruned) => non_neg_integer()}} | {:error, :partition_unavailable}
  def prune(instance_module, partition, timeout \\ @default_call_timeout) do
    with_pid(instance_module, partition, fn pid ->
      GenServer.call(pid, :prune, timeout)
    end)
  end

  @impl true
  def init(opts) do
    state = %{
      instance_module: Keyword.fetch!(opts, :instance_module),
      partition: Keyword.fetch!(opts, :partition),
      table: :ets.new(:session_manager_routes, [:set, :private]),
      ttl_ms: Keyword.fetch!(opts, :ttl_ms),
      max_entries_per_partition: Keyword.fetch!(opts, :max_entries_per_partition),
      prune_interval_ms: Keyword.fetch!(opts, :prune_interval_ms),
      order: :queue.new(),
      next_seq: 0
    }

    schedule_prune(state.prune_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:set, session_key, route, opts}, _from, state) do
    now = monotonic_ms()
    ttl_ms = ttl_for_opts(opts, state.ttl_ms)
    {state, evicted_count} = store_entry(state, session_key, route, ttl_ms, now)

    emit_event(
      [:jido_messaging, :session_route, :set],
      %{count: 1, evicted: evicted_count, entries: table_size(state)},
      state,
      %{session_key: session_key}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, session_key}, _from, state) do
    now = monotonic_ms()
    {state, lookup} = fetch_entry(state, session_key, now)

    reply =
      case lookup do
        {:ok, entry} ->
          {:ok,
           %{
             route: entry.route,
             updated_at_ms: entry.updated_at_ms,
             expires_at_ms: entry.expires_at_ms
           }}

        :expired ->
          {:error, :expired}

        :missing ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:resolve, session_key, fallback_routes}, _from, state) do
    now = monotonic_ms()
    room_scope_key = room_scope_key(session_key)

    {state, exact_lookup} = fetch_entry(state, session_key, now)

    stale_exact? = exact_lookup == :expired

    cond do
      match?({:ok, _entry}, exact_lookup) ->
        {:ok, entry} = exact_lookup

        resolution = %{
          external_room_id: entry.route.external_room_id,
          route: entry.route,
          partition: state.partition,
          session_key: session_key,
          source: :state_hit,
          fallback: false,
          stale: false
        }

        emit_resolved(state, resolution)
        {:reply, {:ok, resolution}, state}

      room_scope_key != session_key ->
        {state, room_lookup} = fetch_entry(state, room_scope_key, now)
        stale_room? = room_lookup == :expired
        stale_any? = stale_exact? or stale_room?

        cond do
          match?({:ok, _entry}, room_lookup) ->
            {:ok, entry} = room_lookup
            {state, _evictions} = store_entry(state, session_key, entry.route, state.ttl_ms, now)

            reason =
              if stale_exact? do
                :stale
              else
                :thread_scope_miss
              end

            resolution =
              %{
                external_room_id: entry.route.external_room_id,
                route: entry.route,
                partition: state.partition,
                session_key: session_key,
                source: :partition_fallback,
                fallback: true,
                stale: stale_any?,
                fallback_reason: reason
              }

            emit_fallback(state, resolution)
            emit_resolved(state, resolution)
            {:reply, {:ok, resolution}, state}

          true ->
            resolve_from_provided_fallback(state, session_key, fallback_routes, stale_any?, now)
        end

      true ->
        resolve_from_provided_fallback(state, session_key, fallback_routes, stale_exact?, now)
    end
  end

  @impl true
  def handle_call(:prune, _from, state) do
    {state, pruned} = prune_expired(state, monotonic_ms())
    {:reply, {:ok, %{pruned: pruned}}, state}
  end

  @impl true
  def handle_info(:prune_tick, state) do
    {state, pruned} = prune_expired(state, monotonic_ms())

    if pruned > 0 do
      emit_event(
        [:jido_messaging, :session_route, :pruned],
        %{count: pruned, entries: table_size(state)},
        state,
        %{}
      )
    end

    schedule_prune(state.prune_interval_ms)
    {:noreply, state}
  end

  defp resolve_from_provided_fallback(state, session_key, fallback_routes, stale_any?, now) do
    case first_valid_fallback(fallback_routes) do
      nil ->
        emit_event(
          [:jido_messaging, :session_route, :resolved],
          %{count: 1},
          state,
          %{outcome: :miss, stale: stale_any?, fallback: false}
        )

        {:reply, {:error, :no_route}, state}

      route ->
        {state, _evictions} = store_entry(state, session_key, route, state.ttl_ms, now)

        reason =
          if stale_any? do
            :stale
          else
            :miss
          end

        resolution = %{
          external_room_id: route.external_room_id,
          route: route,
          partition: state.partition,
          session_key: session_key,
          source: :provided_fallback,
          fallback: true,
          stale: stale_any?,
          fallback_reason: reason
        }

        emit_fallback(state, resolution)
        emit_resolved(state, resolution)
        {:reply, {:ok, resolution}, state}
    end
  end

  defp store_entry(state, session_key, route, ttl_ms, now) do
    seq = state.next_seq + 1

    entry = %{
      route: route,
      updated_at_ms: now,
      expires_at_ms: now + ttl_ms,
      seq: seq
    }

    :ets.insert(state.table, {session_key, entry})

    state = %{state | order: :queue.in({seq, session_key}, state.order), next_seq: seq}
    evict_overflow(state, 0)
  end

  defp evict_overflow(state, evicted_count) do
    if table_size(state) <= state.max_entries_per_partition do
      {state, evicted_count}
    else
      case :queue.out(state.order) do
        {:empty, queue} ->
          {%{state | order: queue}, evicted_count}

        {{:value, {seq, session_key}}, queue} ->
          state = %{state | order: queue}

          case :ets.lookup(state.table, session_key) do
            [{^session_key, %{seq: ^seq} = entry}] ->
              :ets.delete(state.table, session_key)

              emit_event(
                [:jido_messaging, :session_route, :evicted],
                %{count: 1, entries: table_size(state)},
                state,
                %{session_key: session_key, reason: :capacity, external_room_id: entry.route.external_room_id}
              )

              evict_overflow(state, evicted_count + 1)

            _ ->
              evict_overflow(state, evicted_count)
          end
      end
    end
  end

  defp fetch_entry(state, session_key, now) do
    case :ets.lookup(state.table, session_key) do
      [{^session_key, entry}] ->
        if entry.expires_at_ms > now do
          {state, {:ok, entry}}
        else
          :ets.delete(state.table, session_key)
          emit_stale(state, session_key)
          {state, :expired}
        end

      [] ->
        {state, :missing}
    end
  end

  defp prune_expired(state, now) do
    pruned =
      :ets.foldl(
        fn {session_key, entry}, acc ->
          if entry.expires_at_ms <= now do
            :ets.delete(state.table, session_key)
            emit_stale(state, session_key)
            acc + 1
          else
            acc
          end
        end,
        0,
        state.table
      )

    {state, pruned}
  end

  defp room_scope_key({channel_type, instance_id, room_id, _thread_id}) do
    {channel_type, instance_id, room_id, nil}
  end

  defp room_scope_key(session_key), do: session_key

  defp first_valid_fallback(routes) do
    Enum.find(routes, fn route ->
      is_map(route) and Map.get(route, :external_room_id) != nil
    end)
  end

  defp ttl_for_opts(opts, default_ttl_ms) do
    case Keyword.get(opts, :ttl_ms) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> default_ttl_ms
    end
  end

  defp emit_resolved(state, resolution) do
    emit_event(
      [:jido_messaging, :session_route, :resolved],
      %{count: 1},
      state,
      %{
        outcome: if(resolution.fallback, do: :fallback, else: :hit),
        source: resolution.source,
        stale: resolution.stale,
        fallback: resolution.fallback,
        reason: Map.get(resolution, :fallback_reason)
      }
    )
  end

  defp emit_fallback(state, resolution) do
    emit_event(
      [:jido_messaging, :session_route, :fallback],
      %{count: 1},
      state,
      %{source: resolution.source, reason: resolution.fallback_reason, stale: resolution.stale}
    )
  end

  defp emit_stale(state, session_key) do
    emit_event(
      [:jido_messaging, :session_route, :stale],
      %{count: 1},
      state,
      %{session_key: session_key}
    )
  end

  defp emit_event(event, measurements, state, metadata) do
    :telemetry.execute(
      event,
      measurements,
      Map.merge(
        %{
          component: :session_manager,
          instance_module: state.instance_module,
          partition: state.partition
        },
        metadata
      )
    )
  end

  defp with_pid(instance_module, partition, fun) do
    case whereis(instance_module, partition) do
      nil -> {:error, :partition_unavailable}
      pid -> fun.(pid)
    end
  end

  defp table_size(state) do
    :ets.info(state.table, :size)
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp schedule_prune(prune_interval_ms) do
    Process.send_after(self(), :prune_tick, prune_interval_ms)
  end

  defp via_tuple(instance_module, partition) do
    {:via, Registry, {registry_name(instance_module), {:session_manager_partition, partition}}}
  end

  defp registry_name(instance_module) do
    Module.concat(instance_module, Registry.Instances)
  end
end
