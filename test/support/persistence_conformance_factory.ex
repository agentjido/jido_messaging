defmodule Jido.Messaging.Test.PersistenceConformanceFactory do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias Jido.Messaging.Persistence.{ETS, SQLite}

  def start_ets, do: ETS.init([])
  def stop_ets(_state), do: :ok

  def start_sqlite do
    path = Path.join(System.tmp_dir!(), "jido-messaging-conformance-#{unique_id()}.sqlite3")
    SQLite.init(path: path)
  end

  def stop_sqlite(state) do
    :ok = Sqlite3.close(state.db)
    File.rm(state.path)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
