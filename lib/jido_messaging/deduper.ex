defmodule Jido.Messaging.Deduper do
  @moduledoc """
  Central message deduplication using ETS with TTL.

  Prevents duplicate processing of inbound messages by tracking claimed and
  completed message keys. Keys expire after a configurable TTL and are
  periodically swept.

  ## Usage

      # Check and mark atomically (returns :new or :duplicate)
      case Deduper.check_and_mark(MyApp.Messaging, {:telegram, "inst_123", 12345}) do
        :new -> process_message()
        :duplicate -> :ok
      end
  """
  use GenServer

  @default_ttl_ms :timer.hours(1)
  @sweep_interval_ms :timer.minutes(1)

  @schema Zoi.struct(
            __MODULE__,
            %{
              instance_module: Zoi.any(),
              table: Zoi.any(),
              ttl_ms: Zoi.integer()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  @type key :: term()
  @type claim_token :: reference()

  # Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check if a key has been seen before and mark it as seen if new.

  Returns `:new` if the key is new (and marks it), `:duplicate` if already seen.
  """
  @spec check_and_mark(module(), key(), non_neg_integer() | nil) :: :new | :duplicate
  def check_and_mark(messaging_module, key, ttl_ms \\ nil) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, {:check_and_mark, key, ttl_ms})
  end

  @doc """
  Atomically claim a key before processing starts.

  Returns `{:ok, token}` for a new or expired key and `:duplicate` while a
  current claim or completed mark exists. The caller must pass the token to
  `commit/4` after successful processing or to `release/3` after a failure.
  """
  @spec claim(module(), key(), non_neg_integer() | nil) :: {:ok, claim_token()} | :duplicate
  def claim(messaging_module, key, ttl_ms \\ nil) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, {:claim, key, ttl_ms})
  end

  @doc "Commit a claimed key as completed."
  @spec commit(module(), key(), claim_token(), non_neg_integer() | nil) :: :ok | {:error, :stale_claim}
  def commit(messaging_module, key, token, ttl_ms \\ nil) when is_reference(token) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, {:commit, key, token, ttl_ms})
  end

  @doc "Release a failed claim so that the key can be retried."
  @spec release(module(), key(), claim_token()) :: :ok | {:error, :stale_claim}
  def release(messaging_module, key, token) when is_reference(token) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, {:release, key, token})
  end

  @doc """
  Check if a key has been seen (without marking).
  """
  @spec seen?(module(), key()) :: boolean()
  def seen?(messaging_module, key) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, {:seen?, key})
  end

  @doc """
  Manually mark a key as seen.
  """
  @spec mark_seen(module(), key(), non_neg_integer() | nil) :: :ok
  def mark_seen(messaging_module, key, ttl_ms \\ nil) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, {:mark_seen, key, ttl_ms})
  end

  @doc """
  Clear all dedupe keys (useful for testing).
  """
  @spec clear(module()) :: :ok
  def clear(messaging_module) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, :clear)
  end

  @doc """
  Get the count of tracked keys.
  """
  @spec count(module()) :: non_neg_integer()
  def count(messaging_module) do
    deduper = deduper_name(messaging_module)
    GenServer.call(deduper, :count)
  end

  defp deduper_name(messaging_module) do
    Module.concat(messaging_module, Deduper)
  end

  # Server implementation

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    table = :ets.new(:deduper, [:set, :private])

    schedule_sweep()

    state =
      struct!(__MODULE__, %{
        instance_module: instance_module,
        table: table,
        ttl_ms: ttl_ms
      })

    {:ok, state}
  end

  @impl true
  def handle_call({:check_and_mark, key, custom_ttl}, _from, state) do
    now = System.monotonic_time(:millisecond)
    ttl = custom_ttl || state.ttl_ms
    expires_at = now + ttl

    case lookup_current(state.table, key, now) do
      {:current, _entry} ->
        {:reply, :duplicate, state}

      :expired_or_missing ->
        :ets.insert(state.table, {key, :seen, expires_at})
        {:reply, :new, state}
    end
  end

  @impl true
  def handle_call({:claim, key, custom_ttl}, _from, state) do
    now = System.monotonic_time(:millisecond)
    ttl = custom_ttl || state.ttl_ms

    case lookup_current(state.table, key, now) do
      {:current, _entry} ->
        {:reply, :duplicate, state}

      :expired_or_missing ->
        token = make_ref()
        :ets.insert(state.table, {key, :claimed, token, now + ttl})
        {:reply, {:ok, token}, state}
    end
  end

  @impl true
  def handle_call({:commit, key, token, custom_ttl}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, :claimed, ^token, _expires_at}] ->
        ttl = custom_ttl || state.ttl_ms
        :ets.insert(state.table, {key, :seen, System.monotonic_time(:millisecond) + ttl})
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :stale_claim}, state}
    end
  end

  @impl true
  def handle_call({:release, key, token}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, :claimed, ^token, _expires_at}] ->
        :ets.delete(state.table, key)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :stale_claim}, state}
    end
  end

  @impl true
  def handle_call({:seen?, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    result =
      match?({:current, _entry}, lookup_current(state.table, key, now))

    {:reply, result, state}
  end

  @impl true
  def handle_call({:mark_seen, key, custom_ttl}, _from, state) do
    now = System.monotonic_time(:millisecond)
    ttl = custom_ttl || state.ttl_ms
    expires_at = now + ttl

    :ets.insert(state.table, {key, :seen, expires_at})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, :ets.info(state.table, :size), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired(state.table)
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_expired(table) do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn entry, acc ->
        if entry_expires_at(entry) <= now do
          key = elem(entry, 0)
          :ets.delete(table, key)
        end

        acc
      end,
      :ok,
      table
    )
  end

  defp lookup_current(table, key, now) do
    case :ets.lookup(table, key) do
      [{^key, :seen, expires_at} = entry] when expires_at > now -> {:current, entry}
      [{^key, :claimed, _token, expires_at} = entry] when expires_at > now -> {:current, entry}
      _ -> :expired_or_missing
    end
  end

  defp entry_expires_at({_key, :seen, expires_at}), do: expires_at
  defp entry_expires_at({_key, :claimed, _token, expires_at}), do: expires_at
end
