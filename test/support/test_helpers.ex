defmodule Jido.Messaging.TestHelpers do
  @moduledoc """
  Shared test helpers for Jido.Messaging tests.
  """

  @doc "Counts outer Messaging requests and instance resources, excluding Chat namespaces and the locator."
  def runtime_entry_count(runtime) do
    table = Jido.Messaging.Runtime.request_table(runtime)
    [{Jido.Messaging.RequestStore, store}] = :ets.lookup(table, Jido.Messaging.RequestStore)
    {:ok, stats} = Jido.Messaging.RequestStore.call(store, :stats)
    db = :sys.get_state(stats.worker).db
    resources = Enum.count(:ets.tab2list(table), &match?({{:resource, _}, _, _, _, _, _}, &1))
    outer_request_count(db, 0, 0) + resources
  end

  # Test inspection only. Read bounded batches; production does not scan IDs.
  defp outer_request_count(db, offset, count) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT key FROM requests LIMIT 100 OFFSET ?")

    rows =
      try do
        :ok = Exqlite.Sqlite3.bind(statement, [offset])
        {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
        rows
      after
        Exqlite.Sqlite3.release(db, statement)
      end

    outer =
      Enum.count(rows, fn [encoded] ->
        case :erlang.binary_to_term(encoded) do
          {:chat, _, _} -> false
          {:chat_failure, _, _} -> false
          _ -> true
        end
      end)

    if length(rows) < 100, do: count + outer, else: outer_request_count(db, offset + 100, count + outer)
  end

  @doc """
  Asserts that a condition becomes true within a timeout.

  This is preferred over `Process.sleep` as it will return as soon as
  the condition is met, making tests faster and less flaky.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 100)
  - `:interval` - Time between checks in milliseconds (default: 5)

  ## Examples

      assert_eventually(fn -> GenServer.call(pid, :ready) end)

      assert_eventually(fn ->
        state = get_state(pid)
        state.count > 5
      end, timeout: 500)
  """
  def assert_eventually(func, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 100)
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_assert_eventually(func, deadline, interval)
  end

  defp do_assert_eventually(func, deadline, interval) do
    if func.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        raise "Condition was not met within timeout"
      else
        Process.sleep(interval)
        do_assert_eventually(func, deadline, interval)
      end
    end
  end

  @doc """
  Waits for a process to terminate.

  Uses process monitoring instead of polling, which is more reliable.
  """
  def await_termination(pid, timeout \\ 100) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        raise "Process did not terminate within #{timeout}ms"
    end
  end
end
