defmodule Jido.Messaging.RequestLedgerTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Errors.Contract
  import Jido.Messaging.TestHelpers
  alias Exqlite.Sqlite3
  alias Jido.Messaging.{RequestLedger, RequestStore}

  setup do
    %{
      table: RequestLedger.new(),
      key: {"principal", "request"},
      payload: {"operation", %{"text" => "hello"}},
      authority: {"grant", 1}
    }
  end

  test "retains successful and failed results and the claim format", context do
    for result <- [{:ok, :completed}, {:error, :failed}] do
      key = {context.key, result}

      assert {:ok, {^key, digest, authority} = claim} =
               RequestLedger.claim(context.table, key, context.payload, context.authority)

      assert is_binary(digest)
      assert authority == context.authority

      assert {:error, %Contract{code: :request_in_progress}} =
               RequestLedger.claim(context.table, key, context.payload, context.authority)

      assert :ok = RequestLedger.complete(context.table, claim, result)
      assert {:cached, ^result} = RequestLedger.claim(context.table, key, context.payload, context.authority)
    end
  end

  test "key includes principal; digest is independent of map insertion order", context do
    payload = {"operation", Map.new([{"a", 1}, {"b", 2}])}
    reversed = {"operation", Map.new([{"b", 2}, {"a", 1}])}
    assert {:ok, claim} = RequestLedger.claim(context.table, context.key, payload, context.authority)
    :ok = RequestLedger.complete(context.table, claim, :result)
    assert {:cached, :result} = RequestLedger.claim(context.table, context.key, reversed, context.authority)
    assert {:ok, _} = RequestLedger.claim(context.table, {"other-principal", "request"}, payload, context.authority)
  end

  test "changed payload or authority does not release a completed ID", context do
    assert {:ok, claim} = RequestLedger.claim(context.table, context.key, context.payload, context.authority)
    :ok = RequestLedger.complete(context.table, claim, :result)

    assert {:error, %Contract{code: :request_conflict}} =
             RequestLedger.claim(context.table, context.key, :changed, context.authority)

    assert {:error, %Contract{code: :request_conflict}} =
             RequestLedger.claim(context.table, context.key, context.payload, {"grant", 2})

    assert {:cached, :result} = RequestLedger.claim(context.table, context.key, context.payload, context.authority)
  end

  test "a live request stays in progress; a dead owner stays unknown", context do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:claim, RequestLedger.claim(context.table, context.key, context.payload, context.authority)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claim, {:ok, _}}

    assert {:error, %Contract{code: :request_in_progress}} =
             RequestLedger.claim(context.table, context.key, context.payload, context.authority)

    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    for _ <- 1..3 do
      assert {:error, %Contract{code: :request_outcome_unknown}} =
               RequestLedger.claim(context.table, context.key, context.payload, context.authority)
    end

    assert :ets.info(context.table, :size) == 1
  end

  test "completed IDs survive cache eviction and resource entries stay unchanged", context do
    resource = {{:resource, "resource-id"}, %{kind: "result", value: :private}}
    :ets.insert(context.table, resource)

    for index <- 1..1_001 do
      key = {"principal", "request-#{index}"}
      {:ok, claim} = RequestLedger.claim(context.table, key, context.payload, context.authority)
      :ok = RequestLedger.complete(context.table, claim, index)
    end

    assert {:cached, 1} =
             RequestLedger.claim(context.table, {"principal", "request-1"}, context.payload, context.authority)

    assert [^resource] = :ets.lookup(context.table, {:resource, "resource-id"})
    assert :ets.info(context.table, :size) == 2
    assert %{cache_entries: 1_000, disk_entries: 1_001} = stats(context.table)
  end

  test "encoded cache bytes are bounded independently of entry count", context do
    value = String.duplicate("large result", 50_000)

    for index <- 1..40 do
      {:ok, claim} = RequestLedger.claim(context.table, index, index, :authority)
      :ok = RequestLedger.complete(context.table, claim, value)
    end

    stat = stats(context.table)
    assert stat.cache_entries < 40
    assert stat.cache_bytes <= 16 * 1_024 * 1_024
    assert stat.sqlite_cache_kib == 2_048
    assert {:cached, ^value} = RequestLedger.claim(context.table, 1, 1, :authority)
    oversized = String.duplicate("x", 17 * 1_024 * 1_024)
    {:ok, claim} = RequestLedger.claim(context.table, :oversized, :payload, :authority)
    :ok = RequestLedger.complete(context.table, claim, oversized)
    assert {:cached, ^oversized} = RequestLedger.claim(context.table, :oversized, :payload, :authority)
    assert stats(context.table).cache_bytes <= 16 * 1_024 * 1_024
  end

  test "concurrent duplicate claims grant one provider admission", context do
    parent = self()

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          result = RequestLedger.claim(context.table, :concurrent, :payload, :authority)
          send(parent, {:admission, result})
          receive do: (:finish -> result)
        end)
      end

    results =
      for _ <- tasks do
        assert_receive {:admission, result}, 1_000
        result
      end

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Contract{code: :request_in_progress}}, &1)) == 31

    for task <- tasks do
      send(task.pid, :finish)
      Task.await(task)
    end

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.claim(context.table, :concurrent, :payload, :authority)
  end

  test "store restart retains exact results and makes running outcomes unknown", context do
    result = {:original, self(), make_ref(), %{private: <<0, 255>>}}
    {:ok, claim} = RequestLedger.claim(context.table, :done, :payload, :authority)
    :ok = RequestLedger.complete(context.table, claim, result)
    {:ok, running} = RequestLedger.claim(context.table, :running, :payload, :authority)
    before = stats(context.table)
    Process.exit(before.worker, :kill)
    assert_eventually(fn -> replacement?(context.table, before.worker) end, timeout: 2_000)
    assert stats(context.table).path == before.path
    assert {:cached, ^result} = RequestLedger.claim(context.table, :done, :payload, :authority)

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.claim(context.table, :running, :payload, :authority)

    assert {:error, %Contract{code: :request_outcome_unknown}} = RequestLedger.complete(context.table, running, :late)

    assert {:error, %Contract{code: :request_conflict}} =
             RequestLedger.claim(context.table, :running, :changed, :authority)

    assert {:ok, _} = RequestLedger.claim(context.table, :new, :payload, :authority)
  end

  test "read failure closes admission until the same store reopens", context do
    {:ok, claim} = RequestLedger.claim(context.table, :done, :payload, :authority)
    :ok = RequestLedger.complete(context.table, claim, :original)
    before = stats(context.table)
    db = :sys.get_state(before.worker).db
    assert :ok = Sqlite3.close(db)

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.claim(context.table, :new, :payload, :authority)

    assert_eventually(fn -> replacement?(context.table, before.worker) end, timeout: 2_000)
    assert {:cached, :original} = RequestLedger.claim(context.table, :done, :payload, :authority)
  end

  test "write failure after an effect keeps the claim unknown", context do
    {:ok, claim} = RequestLedger.claim(context.table, :effect, :payload, :authority)
    before = stats(context.table)
    db = :sys.get_state(before.worker).db
    :ok = Sqlite3.execute(db, "PRAGMA query_only=ON")

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.complete(context.table, claim, :effect_done)

    assert_eventually(fn -> replacement?(context.table, before.worker) end, timeout: 2_000)

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.claim(context.table, :effect, :payload, :authority)

    assert {:error, %Contract{code: :request_outcome_unknown}} = RequestLedger.complete(context.table, claim, :late)
  end

  test "full disk rejects completion without releasing the request ID", context do
    {:ok, claim} = RequestLedger.claim(context.table, :full, :payload, :authority)
    before = stats(context.table)
    db = :sys.get_state(before.worker).db
    :ok = Sqlite3.execute(db, "PRAGMA max_page_count=#{before.pages}")

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.complete(context.table, claim, String.duplicate("x", 1_024 * 1_024))

    assert_eventually(fn -> replacement?(context.table, before.worker) end, timeout: 2_000)

    assert {:error, %Contract{code: :request_outcome_unknown}} =
             RequestLedger.claim(context.table, :full, :payload, :authority)
  end

  test "missing history never becomes an empty ledger", context do
    {:ok, claim} = RequestLedger.claim(context.table, :done, :payload, :authority)
    :ok = RequestLedger.complete(context.table, claim, :original)
    before = stats(context.table)
    store = store(context.table)
    :ok = :sys.suspend(store)
    GenServer.stop(before.worker)
    :ok = File.rename(before.path, before.path <> ".saved")
    :ok = :sys.resume(store)

    try do
      retry = :sys.get_state(store).retry
      assert is_reference(retry)
      assert_eventually(fn -> :sys.get_state(store).retry != retry end, timeout: 1_000)

      for _ <- 1..3 do
        assert {:error, %Contract{code: :request_outcome_unknown}} =
                 RequestLedger.claim(context.table, :done, :payload, :authority)
      end

      assert Process.alive?(store)
      refute File.exists?(before.path)
    after
      File.rename!(before.path <> ".saved", before.path)
    end

    assert_eventually(fn -> replacement?(context.table, before.worker) end, timeout: 2_000)
    assert {:cached, :original} = RequestLedger.claim(context.table, :done, :payload, :authority)
  end

  test "owner shutdown closes the file and ends the retention lifetime" do
    parent = self()

    owner =
      spawn(fn ->
        table = RequestLedger.new()
        send(parent, {:store_ready, table, stats(table)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:store_ready, table, stat}, 1_000
    store = store(table)
    ref = Process.monitor(store)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^store, :normal}, 1_000
    refute File.exists?(Path.dirname(stat.path))
    assert :ets.info(table) == :undefined
    assert {:error, %Contract{code: :request_outcome_unknown}} = RequestLedger.claim(table, :new, :payload, :authority)
  end

  test "status reports exclude stored results and private failure data", context do
    {:ok, claim} = RequestLedger.claim(context.table, :secret, :payload, :authority)
    :ok = RequestLedger.complete(context.table, claim, "private stored result")
    stat = stats(context.table)

    for process <- [store(context.table), stat.worker] do
      refute inspect(:sys.get_status(process)) =~ "private stored result"
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Contract{code: :request_outcome_unknown}} =
                 RequestStore.call(stat.worker, {:unexpected, "private provider cause"})

        assert_eventually(fn -> replacement?(context.table, stat.worker) end, timeout: 2_000)
        Process.unlink(store(context.table))

        assert {:error, %Contract{code: :request_outcome_unknown}} =
                 RequestStore.call(store(context.table), {:unexpected, "private caller cause"})
      end)

    refute log =~ "private stored result"
    refute log =~ "private provider cause"
    refute log =~ "private caller cause"

    assert %{state: :private_request_history, reason: :request_store_failed, message: :private_request_history, log: []} =
             RequestStore.format_status(%{
               state: "private stored result",
               reason: "private cause",
               message: "private call",
               log: ["private trace"]
             })
  end

  defp store(table) do
    [{RequestStore, store}] = :ets.lookup(table, RequestStore)
    store
  end

  defp stats(table) do
    {:ok, stats} = RequestStore.call(store(table), :stats)
    stats
  end

  defp replacement?(table, old) do
    case RequestStore.call(store(table), :stats) do
      {:ok, %{worker: worker}} -> is_pid(worker) and worker != old
      _ -> false
    end
  end
end
