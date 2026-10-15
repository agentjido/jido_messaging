defmodule Jido.Messaging.RequestStore.Worker do
  @moduledoc false
  use GenServer
  alias Exqlite.Sqlite3

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    epoch = Keyword.fetch!(opts, :epoch)

    with true <- File.regular?(path),
         {:ok, db} <- Sqlite3.open(path) do
      case initialize(db, epoch, Keyword.get(opts, :new, false)) do
        {:ok, generation} ->
          {:ok, %{db: db, generation: generation}}

        _ ->
          Sqlite3.close(db)
          {:stop, :request_store_unavailable}
      end
    else
      _ -> {:stop, :request_store_unavailable}
    end
  end

  @impl true
  def handle_call(operation, from, state) do
    request(operation, from, state)
  rescue
    _ -> {:reply, {:error, :request_store_unavailable}, state}
  catch
    _, _ -> {:reply, {:error, :request_store_unavailable}, state}
  end

  defp request({:read, key}, _from, state) do
    result =
      query(
        state.db,
        "SELECT entry, CASE WHEN status = 0 AND generation <> ? THEN 2 ELSE status END FROM requests WHERE key = ? LIMIT 1",
        [state.generation, blob(key)]
      )

    {:reply, result, state}
  end

  defp request({:write, key, entry, status}, _from, state) do
    result =
      query(state.db, "INSERT OR REPLACE INTO requests(key, entry, status, generation) VALUES (?, ?, ?, ?)", [
        blob(key),
        blob(entry),
        status,
        state.generation
      ])

    {:reply, result, state}
  end

  defp request(:stats, _from, state) do
    with {:ok, [[count]]} <- query(state.db, "SELECT count(*) FROM requests", []),
         {:ok, [[pages]]} <- query(state.db, "PRAGMA page_count", []),
         {:ok, [[page_size]]} <- query(state.db, "PRAGMA page_size", []),
         {:ok, [[cache_size]]} <- query(state.db, "PRAGMA cache_size", []) do
      {:reply, {:ok, %{disk_entries: count, pages: pages, page_size: page_size, sqlite_cache_kib: -cache_size}}, state}
    else
      _ -> {:reply, {:error, :request_store_unavailable}, state}
    end
  end

  defp request(_operation, _from, state),
    do: {:stop, :request_store_failed, Jido.Chat.Signal.Policy.error(:request_outcome_unknown), state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  @impl true
  def format_status(status), do: Jido.Messaging.RequestStore.format_status(status)

  defp initialize(db, epoch, new?) do
    with :ok <- Sqlite3.set_busy_timeout(db, 1_000),
         :ok <-
           Sqlite3.execute(
             db,
             "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-2048; PRAGMA mmap_size=0; PRAGMA wal_autocheckpoint=1000"
           ),
         :ok <- initialize_epoch(db, epoch, new?),
         {:ok, [[generation]]} <- query(db, "UPDATE epoch SET generation = generation + 1 RETURNING generation", []) do
      # One persisted generation makes earlier running rows unknown on read.
      # Recovery does not scan or rewrite an unbounded set of request IDs.
      {:ok, generation}
    end
  end

  defp initialize_epoch(db, epoch, true) do
    with :ok <-
           Sqlite3.execute(
             db,
             "CREATE TABLE epoch (id BLOB NOT NULL, generation INTEGER NOT NULL); CREATE TABLE requests (key BLOB PRIMARY KEY, entry BLOB NOT NULL, status INTEGER NOT NULL, generation INTEGER NOT NULL) WITHOUT ROWID"
           ),
         {:ok, []} <- query(db, "INSERT INTO epoch(id, generation) VALUES (?, 0)", [blob(epoch)]) do
      :ok
    end
  end

  defp initialize_epoch(db, epoch, false) do
    case query(db, "SELECT id FROM epoch LIMIT 2", []) do
      {:ok, [[^epoch]]} -> :ok
      _ -> {:error, :request_store_unavailable}
    end
  end

  defp query(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params) do
          collect_rows(db, statement, [], 100)
        end
      after
        Sqlite3.release(db, statement)
      end
    end
  rescue
    _ -> {:error, :request_store_unavailable}
  catch
    _, _ -> {:error, :request_store_unavailable}
  end

  defp collect_rows(db, statement, rows, remaining) do
    case Sqlite3.step(db, statement) do
      :done -> {:ok, Enum.reverse(rows)}
      {:row, row} when remaining > 0 -> collect_rows(db, statement, [row | rows], remaining - 1)
      _ -> {:error, :request_store_unavailable}
    end
  end

  defp blob(binary), do: {:blob, binary}
end
