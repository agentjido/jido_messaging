alias Jido.Messaging.{RequestLedger, RequestStore}
import Bitwise

sample = fn operation ->
  values =
    for index <- 1..1_000 do
      {elapsed, _} = :timer.tc(fn -> operation.(index) end)
      elapsed
    end
    |> Enum.sort()

  %{p50_us: Enum.at(values, 499), p95_us: Enum.at(values, 949), p99_us: Enum.at(values, 989)}
end

table = RequestLedger.new()
[{RequestStore, store}] = :ets.lookup(table, RequestStore)
before_breakdown = Map.new(:erlang.memory())
before = before_breakdown.total

{elapsed, _} =
  :timer.tc(fn ->
    for index <- 1..100_000 do
      {:ok, claim} = RequestLedger.claim(table, index, {:payload, index}, :authority)
      :ok = RequestLedger.complete(table, claim, {:result, index, String.duplicate("x", 256)})
    end
  end)

:erlang.garbage_collect()
{:ok, stat} = RequestStore.call(store, :stats)
true = stat.cache_entries <= 1_000 and stat.cache_bytes <= 16 * 1_024 * 1_024
{:memory, worker_memory} = Process.info(stat.worker, :memory)
{:memory, owner_memory} = Process.info(store, :memory)
file_bytes = Enum.reduce(Path.wildcard(stat.path <> "*"), 0, fn path, size -> size + File.stat!(path).size end)
beam_delta = :erlang.memory(:total) - before
:erlang.garbage_collect(store)
:erlang.garbage_collect(stat.worker)
after_breakdown = Map.new(:erlang.memory())
beam_after_gc = after_breakdown.total - before
IO.inspect(before_breakdown, label: "before memory")
IO.inspect(after_breakdown, label: "after memory")

processes =
  for pid <- [self(), store, stat.worker],
      do: {pid, Process.info(pid, [:memory, :total_heap_size, :heap_size, :message_queue_len])}

IO.inspect(processes, label: "measured process memory")
db = :sys.get_state(stat.worker).db
:ok = Exqlite.Sqlite3.enable_load_extension(db, true)
probe_path = Path.join(__DIR__, "request_memory_probe.dylib")
:ok = Exqlite.Sqlite3.execute(db, "SELECT load_extension('#{probe_path}')")
:ok = Exqlite.Sqlite3.enable_load_extension(db, false)

{:ok, statement} =
  Exqlite.Sqlite3.prepare(
    db,
    "SELECT probe_sqlite_total(), probe_sqlite_peak(), probe_sqlite_connection(1), probe_sqlite_connection(2), probe_sqlite_connection(3)"
  )

{:row, [native_total, native_peak, native_cache, native_schema, native_statements]} =
  Exqlite.Sqlite3.step(db, statement)

:ok = Exqlite.Sqlite3.release(db, statement)

native_memory = %{
  allocator_current_bytes: native_total,
  allocator_peak_bytes: native_peak,
  connection_page_cache_bytes: native_cache,
  connection_schema_bytes: native_schema,
  connection_statement_bytes: native_statements
}

cache_hit = sample.(fn _ -> {:cached, _} = RequestLedger.claim(table, 100_000, {:payload, 100_000}, :authority) end)
disk_hit = sample.(fn i -> {:cached, _} = RequestLedger.claim(table, i, {:payload, i}, :authority) end)
new_claim = sample.(fn i -> {:ok, _} = RequestLedger.claim(table, 100_000 + i, {:payload, i}, :authority) end)
old_worker = stat.worker
Process.exit(old_worker, :kill)

wait = fn recur, remaining ->
  if remaining == 0, do: raise("store did not recover")

  case RequestStore.call(store, :stats) do
    {:ok, %{worker: worker}} when worker != old_worker ->
      :ok

    _ ->
      Process.sleep(10)
      recur.(recur, remaining - 1)
  end
end

wait.(wait, 200)
{:cached, {:result, 1, text}} = RequestLedger.claim(table, 1, {:payload, 1}, :authority)
true = text == String.duplicate("x", 256)
{:ok, oldest_stat} = File.stat(stat.path)
true = (oldest_stat.mode &&& 0o777) == 0o600

report = %{
  count: 100_000,
  elapsed_us: elapsed,
  ets_entries: :ets.info(table, :size),
  ets_bytes: :ets.info(table, :memory) * :erlang.system_info(:wordsize),
  beam_total_delta: beam_delta,
  beam_total_delta_after_store_gc: beam_after_gc,
  store_process_bytes: owner_memory,
  worker_process_bytes: worker_memory,
  cache_entries: stat.cache_entries,
  cache_encoded_bytes: stat.cache_bytes,
  file_bytes_including_wal: file_bytes,
  sqlite_cache_budget_kib: stat.sqlite_cache_kib,
  native_sqlite_bytes: native_memory,
  hit: cache_hit,
  disk_hit: disk_hit,
  new_claim: new_claim,
  oldest_after_restart: true,
  otp: System.otp_release(),
  elixir: System.version(),
  schedulers: System.schedulers_online(),
  beam_before: before_breakdown,
  beam_after_store_gc: after_breakdown,
  host: "macOS arm64; OTP 29.1; Elixir 1.20.4; 10 schedulers"
}

report_path = System.get_env("JIDO_RETENTION_REPORT") || Path.join(System.tmp_dir!(), "jido-request-retention.json")
File.write!(report_path, Jason.encode!(report, pretty: true))
IO.inspect(report)

GenServer.stop(store)
