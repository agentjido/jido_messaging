defmodule Jido.Messaging.Test.PersistenceConformanceFactory do
  @moduledoc false

  alias Jido.Messaging.Persistence.{ETS, Postgres, SQLite}

  @doc "Starts an isolated ETS adapter for the conformance suite."
  @spec start_ets() :: {:ok, ETS.t()}
  def start_ets, do: ETS.init([])

  @doc "Stops an ETS conformance adapter."
  @spec stop_ets(ETS.t()) :: :ok
  def stop_ets(_state), do: :ok

  @doc "Starts an isolated SQLite adapter for the conformance suite."
  @spec start_sqlite() :: {:ok, SQLite.t()} | {:error, term()}
  def start_sqlite do
    path = Path.join(System.tmp_dir!(), "jido-messaging-conformance-#{unique_id()}.sqlite3")
    SQLite.init(path: path)
  end

  @doc "Stops and removes a SQLite conformance database."
  @spec stop_sqlite(SQLite.t()) :: :ok | {:error, File.posix()}
  def stop_sqlite(state) do
    :ok = SQLite.close(state)
    File.rm(state.path)
  end

  @doc "Starts an isolated PostgreSQL namespace for the conformance suite."
  @spec start_postgres() :: {:ok, Postgres.t()} | {:error, term()}
  def start_postgres do
    with {:ok, state} <-
           Postgres.init(
             url: System.fetch_env!("JIDO_MESSAGING_POSTGRES_URL"),
             migrate: true,
             instance_id: "conformance-#{unique_id()}"
           ) do
      Process.unlink(state.pool)
      {:ok, state}
    end
  end

  @doc "Removes a PostgreSQL conformance namespace and stops its pool."
  @spec stop_postgres(Postgres.t()) :: :ok
  def stop_postgres(state) do
    if Process.alive?(state.pool) do
      _result =
        Postgrex.query(
          state.conn,
          "DELETE FROM jido_messaging_records WHERE instance_id = $1",
          [state.instance_id]
        )
    end

    Postgres.close(state)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
