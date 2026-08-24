defmodule Jido.Messaging.Test.PersistenceConformanceFactory do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias Jido.Messaging.Persistence.{ETS, SQLite}

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
    :ok = Sqlite3.close(state.db)
    File.rm(state.path)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
