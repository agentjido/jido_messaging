# PostgreSQL Persistence

PostgreSQL is the production persistence adapter for Jido Messaging. It gives
the runtime a connection pool, concurrent writers, database transactions, and
stable storage across process and node restarts.

Use SQLite for demos, local development, and tests. SQLite remains supported,
but it is not the production recommendation. Use ETS only when loss after a
BEAM restart is acceptable.

## Integration boundary

`Jido.Messaging.Persistence.Postgres` uses Postgrex directly. An Ecto adapter
would add repository, schema, and migration ownership to the host application.
It would also add Ecto as a required dependency. Direct Postgrex keeps the
boundary small and matches the existing direct SQLite adapter.

The package owns these fixed tables:

- `jido_messaging_schema_migrations`
- `jido_messaging_records`

The record table stores the canonical Erlang record as `BYTEA`. It also stores
indexed columns for rooms, threads, senders, channels, bridges, external IDs,
and message order. The primary key is `{instance_id, kind, id}`. External room
and participant binding constraints also start with `instance_id`.

The package does not use dynamic table names. This prevents unsafe identifier
construction and keeps migration ownership clear.

## Install migrations

Run migrations before the application starts:

```bash
JIDO_MESSAGING_POSTGRES_URL="$DATABASE_URL" \
  mix jido_messaging.postgres.migrate
```

For an Elixir release, call the public migration function from a release task:

```elixir
Jido.Messaging.Persistence.Postgres.migrate(
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: 1
)
```

The runner uses one PostgreSQL transaction and a transaction advisory lock.
Concurrent release nodes can call it safely. It records each installed version
in the package migration table. Runtime initialization fails with
`{:migration_required, database_version, pending_versions}` when migrations are
not current. Set `migrate: true` only for a demo or a host that explicitly lets
the runtime own schema changes.

This release does not move SQLite data into PostgreSQL. Plan an application
export and import when you change adapters. Keep the same `instance_id` if the
import must preserve the instance namespace.

## Let the messaging runtime own the pool

```elixir
defmodule MyApp.Messaging do
  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.Postgres
end

children = [
  {MyApp.Messaging,
   persistence_opts: [
     url: System.fetch_env!("DATABASE_URL"),
     instance_id: "my-app-messaging",
     pool_size: 10,
     migrate: false
   ]}
]
```

The Postgrex pool is linked to the messaging runtime. A runtime stop closes the
pool. A pool failure also stops the runtime so its supervisor can restart the
complete storage boundary.

You can use `connection_options` instead of `url`:

```elixir
persistence_opts: [
  connection_options: [
    hostname: System.fetch_env!("PGHOST"),
    database: System.fetch_env!("PGDATABASE"),
    username: System.fetch_env!("PGUSER"),
    password: System.fetch_env!("PGPASSWORD"),
    ssl: true,
    pool_size: 10,
    queue_target: 100,
    queue_interval: 1_000
  ]
]
```

Postgrex hides sensitive connection data in connection errors. The adapter also
forces this protection on. Do not log persistence options or database URLs.

## Use a host-owned pool

Start Postgrex in the host supervision tree and pass its name or pid:

```elixir
children = [
  {Postgrex,
   name: MyApp.MessagingPostgres,
   hostname: System.fetch_env!("PGHOST"),
   database: System.fetch_env!("PGDATABASE"),
   username: System.fetch_env!("PGUSER"),
   password: System.fetch_env!("PGPASSWORD"),
   ssl: true,
   pool_size: 10},
  {MyApp.Messaging,
   persistence_opts: [
     pool: MyApp.MessagingPostgres,
     instance_id: "my-app-messaging"
   ]}
]
```

The adapter does not stop a host-owned pool. The host must start the pool before
the messaging runtime and must stop it after the runtime.

## Transactions and binding claims

`Postgres.transaction/2` gives the callback an adapter state that is pinned to
one checked-out connection. Return `{:ok, value}` to commit. Return
`{:error, reason}` to roll back.

Room and participant get-or-create operations use transactions and partial
unique indexes. The database selects one winner when writers on different
nodes claim the same external identity. A losing writer reads the committed
winner. It does not leave its candidate record behind.

The adapter reports these capabilities:

- `:durable`
- `:transactions`
- `:concurrent_writers`

It does not report RFC 0001's `:transactional_delivery` capability. That
capability also requires durable inbox, outbox, lease, fencing, attempt, and
retention records. This adapter supplies the transaction boundary needed for
that later work without making a false delivery guarantee now.

PostgreSQL uses `READ COMMITTED` unless the host changes the connection or
transaction setting. Keep transactions short. Do not make provider or network
calls while a database transaction is open.

## Instance isolation

Use a stable, nonempty `instance_id`. The runtime uses its module name when the
option is absent. Set an explicit value before a module rename.

All adapter SQL includes the instance namespace. The primary key and binding
indexes also include it. Two instances can use the same canonical IDs and the
same database without access to each other's records.

Database roles are still an important boundary. Give the runtime only the
table permissions it needs. Use a separate database when a deployment needs a
database-enforced tenant boundary stronger than the adapter namespace.

## Health and telemetry

`Postgres.health_check/1` checks the pool and the migration version. It returns
`:ok` only when both package tables exist and all migrations are current.
An active messaging module exposes the same check as
`MyApp.Messaging.persistence_health/0`. It exposes the selected adapter
guarantees as `MyApp.Messaging.persistence_capabilities/0`.

The adapter emits these events:

- `[:jido_messaging, :persistence, :query]`
- `[:jido_messaging, :persistence, :health_check]`
- `[:jido_messaging, :persistence, :migration, :start]`
- `[:jido_messaging, :persistence, :migration, :stop]`

Query metadata contains the adapter, instance ID, operation name, and result.
It does not contain SQL, parameters, connection options, payloads, or
credentials. DBConnection also supplies pool connection telemetry.

Set the pool size from measured concurrency and database limits. Monitor pool
checkout failures and query duration. A large pool can increase database load
and lock contention. A small pool can increase queue time. Use finite query
timeouts and alert when `health_check/1` fails.
