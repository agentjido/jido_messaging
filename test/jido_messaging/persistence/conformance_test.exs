defmodule Jido.Messaging.Persistence.ETSConformanceTest do
  use Jido.Messaging.Persistence.Conformance,
    adapter: Jido.Messaging.Persistence.ETS,
    factory: {Jido.Messaging.Test.PersistenceConformanceFactory, :start_ets, []},
    cleanup: {Jido.Messaging.Test.PersistenceConformanceFactory, :stop_ets, []},
    async: true
end

defmodule Jido.Messaging.Persistence.SQLiteConformanceTest do
  use Jido.Messaging.Persistence.Conformance,
    adapter: Jido.Messaging.Persistence.SQLite,
    factory: {Jido.Messaging.Test.PersistenceConformanceFactory, :start_sqlite, []},
    cleanup: {Jido.Messaging.Test.PersistenceConformanceFactory, :stop_sqlite, []}
end
