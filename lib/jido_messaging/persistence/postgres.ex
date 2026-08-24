defmodule Jido.Messaging.Persistence.Postgres do
  @moduledoc """
  Production PostgreSQL persistence adapter for `Jido.Messaging`.

  The adapter stores canonical records in one package-owned table. Every key,
  lookup, and unique binding includes a stable `:instance_id`. Two messaging
  instances can therefore use one database without access to each other's data.

  Postgrex is the integration boundary. Supply a host-owned pool with `:pool`,
  or supply `:connection_options` or `:url` and let this adapter own a pool.
  Adapter-owned pools use ten connections by default.

  Migrations are manual by default. Run `migrate/1` during a release, or set
  `migrate: true` only when the runtime is allowed to install migrations.
  Migration work uses a PostgreSQL advisory lock and a package-specific
  migration table.

  ## Options

    * `:instance_id` - Stable record namespace. Defaults to `"default"` for
      direct adapter use. A `Jido.Messaging` runtime supplies its module name.
    * `:pool` - Host-owned Postgrex pool name or pid. The adapter does not stop it.
    * `:connection_options` - Options passed to `Postgrex.start_link/1`.
    * `:url` - PostgreSQL URL used when `:connection_options` is absent.
    * `:migrate` - Install pending package migrations during `init/1`.
      Defaults to `false`.
    * `:query_timeout` - Query checkout and execution timeout. Defaults to
      15 seconds.

  Connection errors, telemetry, and migration errors never include connection
  options, SQL parameters, or credentials.
  """

  @behaviour Jido.Messaging.Persistence
  @behaviour Jido.Messaging.Directory

  alias Jido.Chat.{Participant, Room}

  alias Jido.Messaging.{
    BridgeConfig,
    IngressSubscription,
    Message,
    RoomBinding,
    RoutingPolicy,
    Thread
  }

  alias Jido.Messaging.Persistence.Postgres.Migrations

  @table "jido_messaging_records"
  @migrations_table "jido_messaging_schema_migrations"
  @migration_lock "agentjido/jido_messaging/postgres_migrations"
  @default_instance_id "default"
  @default_pool_size 10
  @default_query_timeout 15_000

  defstruct [:conn, :pool, :instance_id, :owned_pool?, query_timeout: @default_query_timeout]

  @type t :: %__MODULE__{
          conn: Postgrex.conn(),
          pool: Postgrex.conn(),
          instance_id: String.t(),
          owned_pool?: boolean(),
          query_timeout: timeout()
        }

  @impl true
  def init(opts) when is_list(opts) do
    instance_id =
      opts
      |> Keyword.get(:instance_id, @default_instance_id)
      |> normalize_instance_id()

    with {:ok, state} <- connect(opts, instance_id) do
      result =
        with :ok <- maybe_migrate(state, Keyword.get(opts, :migrate, false)),
             :ok <- health_check(state) do
          {:ok, state}
        end

      if match?({:error, _reason}, result), do: close(state)
      result
    end
  end

  @impl true
  def capabilities(_state), do: [:durable, :transactions, :concurrent_writers]

  @impl true
  def health_check(state) do
    started_at = System.monotonic_time()

    result =
      with {:ok, %Postgrex.Result{rows: [[1]]}} <-
             query(state, "SELECT 1", [], :health_check),
           {:ok, _status} <- migration_status(state) do
        :ok
      end

    emit_health_check(state, started_at, result)
    result
  end

  @doc "Return the installed and required package schema versions."
  @spec migration_status(t()) :: {:ok, map()} | {:error, term()}
  def migration_status(state) do
    with {:ok, %Postgrex.Result{rows: [[migrations_table, records_table]]}} <-
           query(
             state,
             "SELECT to_regclass($1), to_regclass($2)",
             [@migrations_table, @table],
             :migration_status
           ),
         :ok <- require_tables(migrations_table, records_table),
         {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             "SELECT version FROM #{@migrations_table} ORDER BY version",
             [],
             :migration_status
           ) do
      applied_versions = Enum.map(rows, &hd/1)
      expected_versions = migration_versions()
      database_version = Enum.max(applied_versions, fn -> 0 end)
      current_version = Migrations.current_version()
      pending_versions = expected_versions -- applied_versions
      unknown_versions = applied_versions -- expected_versions

      cond do
        unknown_versions != [] ->
          {:error, {:unsupported_schema_version, Enum.max(unknown_versions), current_version}}

        pending_versions == [] ->
          {:ok,
           %{
             database_version: database_version,
             current_version: current_version,
             pending_versions: []
           }}

        true ->
          {:error, {:migration_required, database_version, pending_versions}}
      end
    end
  end

  @doc "Install pending migrations with adapter state, a host pool, options, or a PostgreSQL URL."
  @spec migrate(t() | keyword()) :: :ok | {:error, term()}
  def migrate(state_or_opts)

  def migrate(%__MODULE__{} = state), do: run_migration_span(state)

  def migrate(opts) when is_list(opts) do
    instance_id =
      opts
      |> Keyword.get(:instance_id, @default_instance_id)
      |> normalize_instance_id()

    with {:ok, state} <- connect(opts, instance_id) do
      try do
        run_migration_span(state)
      after
        close(state)
      end
    end
  end

  @impl true
  def close(%__MODULE__{owned_pool?: false}), do: :ok

  def close(%__MODULE__{pool: pool, owned_pool?: true}) do
    if is_pid(pool) and Process.alive?(pool) do
      try do
        GenServer.stop(pool, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  @impl true
  def transaction(state, fun) when is_function(fun, 1) do
    result =
      Postgrex.transaction(
        state.conn,
        fn conn ->
          transaction_state = %{state | conn: conn}

          case fun.(transaction_state) do
            {:ok, _value} = result -> result
            {:error, reason} -> Postgrex.rollback(conn, reason)
            other -> Postgrex.rollback(conn, {:invalid_transaction_result, other})
          end
        end,
        timeout: state.query_timeout
      )

    case result do
      {:ok, transaction_result} -> transaction_result
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  @impl true
  def save_room(state, %Room{} = room) do
    persist(state, "room", room.id, room, room_id: room.id)
  end

  @impl true
  def get_room(state, room_id), do: fetch_record(state, "room", room_id)

  @impl true
  def delete_room(state, room_id) do
    run(
      state,
      """
      DELETE FROM #{@table}
      WHERE instance_id = $1
        AND ((kind = 'room' AND id = $2)
         OR (kind IN ('message', 'thread', 'room_binding', 'routing_policy') AND room_id = $2))
      """,
      [state.instance_id, room_id],
      :delete_room
    )
  end

  @impl true
  def list_rooms(state, opts \\ []) do
    list_records(state, "room", opts, order: "inserted_at ASC, id ASC")
  end

  @impl true
  def save_participant(state, %Participant{} = participant) do
    persist(state, "participant", participant.id, participant)
  end

  @impl true
  def get_participant(state, participant_id), do: fetch_record(state, "participant", participant_id)

  @impl true
  def delete_participant(state, participant_id) do
    run(
      state,
      """
      DELETE FROM #{@table}
      WHERE instance_id = $1
        AND ((kind = 'participant' AND id = $2)
          OR (kind = 'participant_binding' AND room_id = $2))
      """,
      [state.instance_id, participant_id],
      :delete_participant
    )
  end

  @impl true
  def save_message(state, %Message{} = message) do
    metadata = message.metadata || %{}

    persist(state, "message", message.id, message,
      room_id: message.room_id,
      thread_id: message.thread_id,
      sender_id: message.sender_id,
      inserted_at: message.inserted_at,
      channel: metadata_value(metadata, :channel),
      bridge_id: metadata_value(metadata, :bridge_id),
      external_id: message.external_id
    )
  end

  @impl true
  def get_message(state, message_id), do: fetch_record(state, "message", message_id)

  @impl true
  def get_messages(state, room_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    thread_id = Keyword.get(opts, :thread_id)

    with {:ok, direction} <- cursor_direction(opts),
         {scope_where, scope_params} <- message_scope(room_id, thread_id),
         {where, params} <- with_instance_scope(state, scope_where, scope_params),
         {:ok, cursor} <- resolve_message_cursor(state, where, params, direction),
         {where, params, order, reverse?} <- apply_message_cursor(where, params, direction, cursor),
         {:ok, rows} <- query_message_page(state, where, params, order, limit) do
      messages = decode_rows(rows)
      {:ok, if(reverse?, do: Enum.reverse(messages), else: messages)}
    end
  end

  @impl true
  def delete_message(state, message_id) do
    delete_record(state, "message", message_id)
  end

  @impl true
  def get_participant_messages(state, participant_id, room_ids, opts \\ [])

  def get_participant_messages(_state, _participant_id, [], _opts), do: {:ok, []}

  def get_participant_messages(state, participant_id, room_ids, opts)
      when is_binary(participant_id) and is_list(room_ids) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)

    if is_integer(limit) and limit > 0 do
      query_participant_messages(state, participant_id, room_ids, opts, limit)
    else
      {:error, :invalid_limit}
    end
  end

  @impl true
  def mark_message_read(state, message_id, participant_id, receipt) do
    with {:ok, message, payload} <- fetch_message_payload(state, message_id) do
      case Jido.Messaging.ReadReceipt.apply_to_message(message, participant_id, receipt) do
        {updated, :updated} ->
          compare_and_swap_message(state, message_id, participant_id, receipt, payload, updated)

        {unchanged, :unchanged} ->
          {:ok, unchanged, :unchanged}
      end
    end
  end

  @impl true
  def save_thread(state, %Thread{} = thread) do
    persist(state, "thread", thread.id, thread,
      room_id: thread.room_id,
      inserted_at: thread.inserted_at,
      external_id: thread.external_thread_id
    )
  end

  @impl true
  def get_thread(state, thread_id), do: fetch_record(state, "thread", thread_id)

  @impl true
  def get_thread_by_external_id(state, room_id, external_thread_id) do
    fetch_one(state, "thread", [
      {"room_id", room_id},
      {"external_id", normalize_term(external_thread_id)}
    ])
  end

  @impl true
  def get_thread_by_root_message(state, room_id, root_message_id) do
    state
    |> list_threads(room_id, limit: 500)
    |> find_record(&(&1.root_message_id == root_message_id))
  end

  @impl true
  def list_threads(state, room_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query_records(
      state,
      "kind = $1 AND room_id = $2",
      ["thread", room_id],
      order: "inserted_at ASC, id ASC",
      limit: limit
    )
  end

  @impl true
  def get_or_create_room_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    transaction(state, fn transaction_state ->
      case get_room_by_external_binding(transaction_state, channel, bridge_id, external_id) do
        {:ok, room} ->
          {:ok, room}

        {:error, :not_found} ->
          room = build_bound_room(channel, bridge_id, external_id, attrs)

          with {:ok, room} <- save_room(transaction_state, room),
               {:ok, _binding} <-
                 create_room_binding(transaction_state, room.id, channel, bridge_id, external_id, %{}) do
            {:ok, room}
          end
      end
    end)
    |> resolve_room_binding_conflict(state, channel, bridge_id, external_id)
  end

  @impl true
  def get_or_create_participant_by_external_id(state, channel, external_id, attrs) do
    get_or_create_participant_by_external_binding(state, channel, "default", external_id, attrs)
  end

  @impl true
  def get_or_create_participant_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    transaction(state, fn transaction_state ->
      case find_participant_binding(transaction_state, channel, bridge_id, external_id) do
        {:ok, participant} ->
          {:ok, participant}

        {:error, :not_found} ->
          claim_legacy_or_create_participant(
            transaction_state,
            channel,
            bridge_id,
            external_id,
            attrs
          )
      end
    end)
  end

  @impl true
  def bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) do
    transaction(state, fn transaction_state ->
      do_bind_participant_external_id(
        transaction_state,
        participant_id,
        channel,
        bridge_id,
        external_id
      )
    end)
    |> public_binding_result()
  end

  @impl true
  def get_message_by_external_id(state, channel, bridge_id, external_id) do
    fetch_one(state, "message", [
      {"channel", normalize_term(channel)},
      {"bridge_id", normalize_term(bridge_id)},
      {"external_id", normalize_term(external_id)}
    ])
  end

  @impl true
  def update_message_external_id(state, message_id, external_id) do
    with {:ok, message} <- get_message(state, message_id) do
      save_message(state, %{message | external_id: external_id})
    end
  end

  @impl true
  def get_room_by_external_binding(state, channel, bridge_id, external_id) do
    with {:ok, binding} <- find_room_binding(state, channel, bridge_id, external_id) do
      get_room(state, binding.room_id)
    end
  end

  @impl true
  def create_room_binding(state, room_id, channel, bridge_id, external_id, attrs) do
    binding =
      RoomBinding.new(
        Map.merge(attrs, %{
          room_id: room_id,
          channel: channel,
          bridge_id: normalize_term(bridge_id),
          external_room_id: normalize_term(external_id)
        })
      )

    persist(state, "room_binding", binding.id, binding,
      room_id: room_id,
      channel: channel,
      bridge_id: binding.bridge_id,
      external_id: binding.external_room_id,
      inserted_at: binding.inserted_at
    )
  end

  @impl true
  def list_room_bindings(state, room_id) do
    query_records(
      state,
      "kind = $1 AND room_id = $2",
      ["room_binding", room_id],
      order: "inserted_at ASC, id ASC",
      limit: 500
    )
  end

  @impl true
  def delete_room_binding(state, binding_id) do
    delete_existing_record(state, "room_binding", binding_id)
  end

  @impl Jido.Messaging.Directory
  def lookup(state, target, query), do: directory_lookup(state, target, query, [])

  @impl Jido.Messaging.Directory
  def search(state, target, query), do: directory_search(state, target, query, [])

  @impl true
  def directory_lookup(state, target, query, opts \\ []) when is_map(query) do
    case directory_search(state, target, query, opts) do
      {:ok, [entry]} -> {:ok, entry}
      {:ok, []} -> {:error, :not_found}
      {:ok, matches} -> {:error, {:ambiguous, matches}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def directory_search(state, :participant, query, opts) when is_map(query) do
    limit = Keyword.get(opts, :limit, 500)

    with {:ok, participants} <- list_records(state, "participant", limit: limit) do
      participants =
        participants
        |> Enum.filter(&participant_matches?(&1, query))
        |> Enum.sort_by(& &1.id)

      {:ok, participants}
    end
  end

  def directory_search(state, :room, query, opts) when is_map(query) do
    limit = Keyword.get(opts, :limit, 500)

    with {:ok, rooms} <- list_records(state, "room", limit: limit) do
      rooms =
        rooms
        |> Enum.filter(&room_matches?(state, &1, query))
        |> Enum.sort_by(& &1.id)

      {:ok, rooms}
    end
  end

  def directory_search(_state, target, _query, _opts) do
    {:error, {:invalid_directory_target, target}}
  end

  @impl true
  def save_onboarding(state, onboarding_flow) when is_map(onboarding_flow) do
    onboarding_id = Map.get(onboarding_flow, :onboarding_id) || Map.get(onboarding_flow, "onboarding_id")

    if is_binary(onboarding_id) and onboarding_id != "" do
      persist(state, "onboarding", onboarding_id, onboarding_flow)
    else
      {:error, :invalid_onboarding_id}
    end
  end

  @impl true
  def get_onboarding(state, onboarding_id), do: fetch_record(state, "onboarding", onboarding_id)

  @impl true
  def save_bridge_config(state, %BridgeConfig{} = bridge_config) do
    with :ok <- BridgeConfig.validate_for_storage(bridge_config) do
      persist(state, "bridge_config", bridge_config.id, bridge_config, inserted_at: bridge_config.inserted_at)
    end
  end

  @impl true
  def get_bridge_config(state, bridge_id), do: fetch_record(state, "bridge_config", bridge_id)

  @impl true
  def list_bridge_configs(state, opts \\ []) do
    enabled_filter = Keyword.get(opts, :enabled)

    with {:ok, configs} <- list_records(state, "bridge_config", opts, order: "id ASC") do
      {:ok, maybe_filter_enabled(configs, enabled_filter)}
    end
  end

  @impl true
  def delete_bridge_config(state, bridge_id) do
    delete_existing_record(state, "bridge_config", bridge_id)
  end

  @impl true
  def save_ingress_subscription(state, %IngressSubscription{} = subscription) do
    id = ingress_subscription_key(subscription.bridge_id, subscription.subscription_id)
    persist(state, "ingress_subscription", id, subscription, room_id: subscription.bridge_id)
  end

  @impl true
  def list_ingress_subscriptions(state, bridge_id, opts \\ []) do
    status_filter = Keyword.get(opts, :status)

    with {:ok, subscriptions} <-
           query_records(
             state,
             "kind = $1 AND room_id = $2",
             ["ingress_subscription", bridge_id],
             order: "id ASC",
             limit: Keyword.get(opts, :limit, 500)
           ) do
      {:ok, maybe_filter_subscription_status(subscriptions, status_filter)}
    end
  end

  @impl true
  def delete_ingress_subscription(state, bridge_id, subscription_id) do
    id = ingress_subscription_key(bridge_id, subscription_id)
    delete_existing_record(state, "ingress_subscription", id)
  end

  @impl true
  def save_routing_policy(state, %RoutingPolicy{} = routing_policy) do
    persist(state, "routing_policy", routing_policy.room_id, routing_policy, room_id: routing_policy.room_id)
  end

  @impl true
  def get_routing_policy(state, room_id), do: fetch_record(state, "routing_policy", room_id)

  @impl true
  def delete_routing_policy(state, room_id) do
    delete_existing_record(state, "routing_policy", room_id)
  end

  defp connect(opts, instance_id) do
    query_timeout = Keyword.get(opts, :query_timeout, @default_query_timeout)

    case Keyword.fetch(opts, :pool) do
      {:ok, pool} ->
        {:ok,
         %__MODULE__{
           conn: pool,
           pool: pool,
           instance_id: instance_id,
           owned_pool?: false,
           query_timeout: query_timeout
         }}

      :error ->
        with {:ok, connection_options} <- connection_options(opts),
             {:ok, pool} <- Postgrex.start_link(connection_options) do
          {:ok,
           %__MODULE__{
             conn: pool,
             pool: pool,
             instance_id: instance_id,
             owned_pool?: true,
             query_timeout: query_timeout
           }}
        end
    end
  end

  defp connection_options(opts) do
    result =
      cond do
        Keyword.has_key?(opts, :connection_options) ->
          case Keyword.fetch!(opts, :connection_options) do
            connection_options when is_list(connection_options) -> {:ok, connection_options}
            _other -> {:error, :invalid_connection_options}
          end

        Keyword.has_key?(opts, :url) ->
          parse_database_url(Keyword.fetch!(opts, :url))

        true ->
          connection_options =
            Keyword.take(opts, [
              :hostname,
              :endpoints,
              :socket_dir,
              :socket,
              :port,
              :database,
              :username,
              :password,
              :parameters,
              :timeout,
              :connect_timeout,
              :handshake_timeout,
              :ping_timeout,
              :ssl,
              :socket_options,
              :target_server_type,
              :disconnect_on_error_codes,
              :prepare,
              :transactions,
              :types,
              :pool_size,
              :queue_target,
              :queue_interval,
              :idle_interval,
              :max_lifetime,
              :name
            ])

          {:ok, connection_options}
      end

    with {:ok, connection_options} <- result do
      {:ok,
       connection_options
       |> Keyword.put_new(:pool_size, Keyword.get(opts, :pool_size, @default_pool_size))
       |> Keyword.put(:show_sensitive_data_on_connection_error, false)}
    end
  end

  defp parse_database_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_database_uri(uri),
         {:ok, auth_options} <- database_auth_options(uri.userinfo),
         {:ok, ssl_options} <- database_ssl_options(uri.query) do
      database = uri.path |> String.trim_leading("/") |> URI.decode()

      {:ok,
       [hostname: uri.host, port: uri.port || 5432, database: database]
       |> Keyword.merge(auth_options)
       |> Keyword.merge(ssl_options)}
    end
  end

  defp parse_database_url(_url), do: {:error, :invalid_database_url}

  defp validate_database_uri(%URI{scheme: scheme, host: host, path: path})
       when scheme in ["postgres", "postgresql"] and is_binary(host) and is_binary(path) and path != "/",
       do: :ok

  defp validate_database_uri(_uri), do: {:error, :invalid_database_url}

  defp database_auth_options(nil), do: {:ok, []}

  defp database_auth_options(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] ->
        {:ok, [username: URI.decode(username), password: URI.decode(password)]}

      [username] ->
        {:ok, [username: URI.decode(username)]}
    end
  end

  defp database_ssl_options(nil), do: {:ok, []}

  defp database_ssl_options(query) do
    options = URI.decode_query(query)
    ssl_mode = Map.get(options, "sslmode") || Map.get(options, "ssl")

    case ssl_mode do
      nil -> {:ok, []}
      value when value in ["true", "require", "verify-ca", "verify-full"] -> {:ok, [ssl: true]}
      value when value in ["false", "disable"] -> {:ok, [ssl: false]}
      _other -> {:error, :invalid_database_ssl_mode}
    end
  end

  defp maybe_migrate(state, true), do: migrate(state)
  defp maybe_migrate(_state, false), do: :ok
  defp maybe_migrate(_state, _value), do: {:error, :invalid_migrate_option}

  defp run_migration_span(state) do
    started_at = System.monotonic_time()

    :telemetry.execute(
      [:jido_messaging, :persistence, :migration, :start],
      %{system_time: System.system_time()},
      %{adapter: __MODULE__}
    )

    result = do_migrate(state)

    :telemetry.execute(
      [:jido_messaging, :persistence, :migration, :stop],
      %{duration: System.monotonic_time() - started_at},
      %{adapter: __MODULE__, result: result_tag(result)}
    )

    result
  end

  defp do_migrate(state) do
    result =
      Postgrex.transaction(
        state.conn,
        fn conn ->
          case migrate_in_transaction(conn) do
            :ok -> :ok
            {:error, reason} -> Postgrex.rollback(conn, reason)
          end
        end,
        timeout: :infinity
      )

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp migrate_in_transaction(conn) do
    with {:ok, _result} <-
           Postgrex.query(conn, "SELECT pg_advisory_xact_lock(hashtext($1))", [@migration_lock], timeout: :infinity),
         {:ok, _result} <- Postgrex.query(conn, create_migrations_table_sql(), [], timeout: :infinity),
         {:ok, versions} <- applied_migration_versions(conn),
         :ok <- validate_database_version(versions),
         :ok <- apply_pending_migrations(conn, versions) do
      :ok
    end
  end

  defp create_migrations_table_sql do
    """
    CREATE TABLE IF NOT EXISTS #{@migrations_table} (
      version BIGINT PRIMARY KEY,
      name TEXT NOT NULL,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    )
    """
  end

  defp applied_migration_versions(conn) do
    case Postgrex.query(conn, "SELECT version FROM #{@migrations_table} ORDER BY version", [], timeout: :infinity) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_database_version(versions) do
    unknown_versions = versions -- migration_versions()
    current_version = Migrations.current_version()

    if unknown_versions == [] do
      :ok
    else
      {:error, {:unsupported_schema_version, Enum.max(unknown_versions), current_version}}
    end
  end

  defp apply_pending_migrations(conn, applied_versions) do
    Migrations.all()
    |> Enum.reject(fn {version, _name, _statements} -> version in applied_versions end)
    |> Enum.reduce_while(:ok, fn migration, :ok ->
      case apply_migration(conn, migration) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_migration(conn, {version, name, statements}) do
    with :ok <- run_migration_statements(conn, statements),
         {:ok, _result} <-
           Postgrex.query(
             conn,
             "INSERT INTO #{@migrations_table} (version, name) VALUES ($1, $2)",
             [version, name],
             timeout: :infinity
           ) do
      :ok
    end
  end

  defp run_migration_statements(conn, statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case Postgrex.query(conn, statement, [], timeout: :infinity) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_tables(migrations_table, records_table)
       when is_nil(migrations_table) or is_nil(records_table),
       do: {:error, {:migration_required, 0, migration_versions()}}

  defp require_tables(_migrations_table, _records_table), do: :ok

  defp migration_versions do
    Migrations.all() |> Enum.map(&elem(&1, 0))
  end

  defp cursor_direction(opts) do
    case {Keyword.get(opts, :before), Keyword.get(opts, :after)} do
      {nil, nil} ->
        {:ok, :none}

      {before, nil} when is_binary(before) and before != "" ->
        {:ok, {:before, before}}

      {nil, after_cursor} when is_binary(after_cursor) and after_cursor != "" ->
        {:ok, {:after, after_cursor}}

      {_before, _after_cursor} ->
        {:error, :invalid_cursor_options}
    end
  end

  defp message_scope(room_id, thread_id) when is_binary(thread_id) do
    {"kind = $1 AND room_id = $2 AND thread_id = $3", ["message", room_id, thread_id]}
  end

  defp message_scope(room_id, _thread_id), do: {"kind = $1 AND room_id = $2", ["message", room_id]}

  defp resolve_message_cursor(_state, _where, _params, :none), do: {:ok, nil}

  defp resolve_message_cursor(state, where, params, {_direction, cursor_id}) do
    cursor_param = length(params) + 1

    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             "SELECT COALESCE(inserted_at, ''), id FROM #{@table} " <>
               "WHERE #{where} AND id = $#{cursor_param} LIMIT 1",
             params ++ [cursor_id],
             :resolve_message_cursor
           ) do
      case rows do
        [[inserted_at, id]] -> {:ok, {inserted_at, id}}
        [] -> {:error, :cursor_not_found}
      end
    end
  end

  defp apply_message_cursor(where, params, :none, nil), do: {where, params, "DESC", true}

  defp apply_message_cursor(where, params, {direction, _cursor_id}, {inserted_at, id}) do
    operator = if direction == :before, do: "<", else: ">"
    timestamp_param = length(params) + 1
    id_param = timestamp_param + 1

    cursor_where =
      "#{where} AND (COALESCE(inserted_at, '') #{operator} $#{timestamp_param} OR " <>
        "(COALESCE(inserted_at, '') = $#{timestamp_param} AND id #{operator} $#{id_param}))"

    order = if direction == :before, do: "DESC", else: "ASC"
    {cursor_where, params ++ [inserted_at, id], order, direction == :before}
  end

  defp query_message_page(state, where, params, order, limit) do
    case query(
           state,
           """
           SELECT payload
           FROM #{@table}
           WHERE #{where}
           ORDER BY COALESCE(inserted_at, '') #{order}, id #{order}
           LIMIT $#{length(params) + 1}
           """,
           params ++ [limit],
           :get_messages
         ) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp query_participant_messages(state, participant_id, room_ids, opts, limit) do
    room_placeholders =
      room_ids
      |> Enum.with_index(3)
      |> Enum.map_join(", ", fn {_room_id, index} -> "$#{index}" end)

    where = "kind = $1 AND sender_id = $2 AND room_id IN (#{room_placeholders})"
    params = ["message", participant_id | room_ids]
    {where, params} = with_instance_scope(state, where, params)

    case participant_cursor_direction(opts) do
      :none ->
        query_participant_page(state, where, params, "DESC", limit, true)

      {:before, cursor_id} ->
        with {:ok, {inserted_at, id}} <- participant_cursor(state, where, params, cursor_id) do
          timestamp_param = length(params) + 1
          id_param = timestamp_param + 1

          cursor_where =
            "#{where} AND (COALESCE(inserted_at, '') < $#{timestamp_param} OR " <>
              "(COALESCE(inserted_at, '') = $#{timestamp_param} AND id < $#{id_param}))"

          query_participant_page(
            state,
            cursor_where,
            params ++ [inserted_at, id],
            "DESC",
            limit,
            true
          )
        end

      {:after, cursor_id} ->
        with {:ok, {inserted_at, id}} <- participant_cursor(state, where, params, cursor_id) do
          timestamp_param = length(params) + 1
          id_param = timestamp_param + 1

          cursor_where =
            "#{where} AND (COALESCE(inserted_at, '') > $#{timestamp_param} OR " <>
              "(COALESCE(inserted_at, '') = $#{timestamp_param} AND id > $#{id_param}))"

          query_participant_page(
            state,
            cursor_where,
            params ++ [inserted_at, id],
            "ASC",
            limit,
            false
          )
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp participant_cursor(state, where, params, cursor_id) do
    cursor_param = length(params) + 1

    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             """
             SELECT COALESCE(inserted_at, ''), id
             FROM #{@table}
             WHERE #{where} AND id = $#{cursor_param}
             LIMIT 1
             """,
             params ++ [cursor_id],
             :resolve_participant_cursor
           ) do
      case rows do
        [[inserted_at, id]] -> {:ok, {inserted_at, id}}
        [] -> {:error, :cursor_not_found}
      end
    end
  end

  defp query_participant_page(state, where, params, direction, limit, reverse?) do
    limit_param = length(params) + 1

    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             """
             SELECT payload
             FROM #{@table}
             WHERE #{where}
             ORDER BY COALESCE(inserted_at, '') #{direction}, id #{direction}
             LIMIT $#{limit_param}
             """,
             params ++ [limit],
             :get_participant_messages
           ) do
      messages = decode_rows(rows)
      {:ok, if(reverse?, do: Enum.reverse(messages), else: messages)}
    end
  end

  defp participant_cursor_direction(opts) do
    case cursor_direction(opts) do
      {:ok, direction} -> direction
      {:error, _reason} = error -> error
    end
  end

  defp persist(state, kind, id, record, opts \\ []) do
    with :ok <- upsert_record(state, kind, id, record, opts) do
      {:ok, record}
    end
  end

  defp upsert_record(state, kind, id, record, opts) do
    run(
      state,
      """
      INSERT INTO #{@table}
        (instance_id, kind, id, room_id, thread_id, sender_id, inserted_at,
         channel, bridge_id, external_id, payload)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      ON CONFLICT (instance_id, kind, id) DO UPDATE SET
        room_id = excluded.room_id,
        thread_id = excluded.thread_id,
        sender_id = excluded.sender_id,
        inserted_at = excluded.inserted_at,
        channel = excluded.channel,
        bridge_id = excluded.bridge_id,
        external_id = excluded.external_id,
        payload = excluded.payload,
        updated_at = clock_timestamp()
      """,
      [
        state.instance_id,
        kind,
        id,
        Keyword.get(opts, :room_id),
        Keyword.get(opts, :thread_id),
        Keyword.get(opts, :sender_id),
        format_datetime(Keyword.get(opts, :inserted_at)),
        opts |> Keyword.get(:channel) |> normalize_nullable(),
        opts |> Keyword.get(:bridge_id) |> normalize_nullable(),
        opts |> Keyword.get(:external_id) |> normalize_nullable(),
        :erlang.term_to_binary(record)
      ],
      :upsert_record
    )
  end

  defp fetch_record(state, kind, id) do
    fetch_one(state, kind, [{"id", id}])
  end

  defp fetch_one(state, kind, filters) do
    {where, params} = where_clause([{"instance_id", state.instance_id}, {"kind", kind} | filters])

    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             """
             SELECT payload
             FROM #{@table}
             WHERE #{where}
             LIMIT 1
             """,
             params,
             :fetch_record
           ) do
      case decode_rows(rows) do
        [record] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    end
  end

  defp list_records(state, kind, opts, sql_opts \\ []) do
    query_records(
      state,
      "kind = $1",
      [kind],
      Keyword.merge(sql_opts, limit: Keyword.get(opts, :limit, 100))
    )
  end

  defp query_records(state, where, params, opts) do
    limit = Keyword.fetch!(opts, :limit)
    order = Keyword.get(opts, :order, "inserted_at ASC, id ASC")
    {where, params} = with_instance_scope(state, where, params)

    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             """
             SELECT payload
             FROM #{@table}
             WHERE #{where}
             ORDER BY #{order}
             LIMIT $#{length(params) + 1}
             """,
             params ++ [limit],
             :list_records
           ) do
      {:ok, decode_rows(rows)}
    end
  end

  defp delete_record(state, kind, id) do
    run(
      state,
      "DELETE FROM #{@table} WHERE instance_id = $1 AND kind = $2 AND id = $3",
      [state.instance_id, kind, id],
      :delete_record
    )
  end

  defp delete_existing_record(state, kind, id) do
    case fetch_record(state, kind, id) do
      {:ok, _record} -> delete_record(state, kind, id)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_instance_scope(state, where, params) do
    instance_param = length(params) + 1
    {"(#{where}) AND instance_id = $#{instance_param}", params ++ [state.instance_id]}
  end

  defp find_record({:ok, records}, predicate) do
    case Enum.find(records, predicate) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp find_record({:error, _reason} = error, _predicate), do: error

  defp fetch_message_payload(state, message_id) do
    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             "SELECT payload FROM #{@table} " <>
               "WHERE instance_id = $1 AND kind = 'message' AND id = $2 LIMIT 1",
             [state.instance_id, message_id],
             :fetch_message_receipts
           ) do
      case rows do
        [[payload]] -> {:ok, decode_payload(payload), payload}
        [] -> {:error, :not_found}
      end
    end
  end

  defp compare_and_swap_message(state, message_id, participant_id, receipt, old_payload, updated) do
    with {:ok, %Postgrex.Result{rows: rows}} <-
           query(
             state,
             """
             UPDATE #{@table}
             SET payload = $1, updated_at = clock_timestamp()
             WHERE instance_id = $2 AND kind = 'message' AND id = $3 AND payload = $4
             RETURNING id
             """,
             [
               :erlang.term_to_binary(updated),
               state.instance_id,
               message_id,
               old_payload
             ],
             :mark_message_read
           ) do
      case rows do
        [[_id]] -> {:ok, updated, :updated}
        [] -> mark_message_read(state, message_id, participant_id, receipt)
      end
    end
  end

  defp do_bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) do
    with {:ok, _participant} <- get_participant(state, participant_id) do
      case find_participant_binding_record(state, channel, bridge_id, external_id) do
        {:ok, %{participant_id: ^participant_id}} ->
          {:ok, :bound}

        {:ok, %{participant_id: existing_participant_id}} ->
          case get_participant(state, existing_participant_id) do
            {:ok, _participant} ->
              {:error, {:external_identity_conflict, existing_participant_id}}

            {:error, :not_found} ->
              :ok = delete_participant_binding_record(state, channel, bridge_id, external_id)
              do_bind_participant_external_id(state, participant_id, channel, bridge_id, external_id)
          end

        {:error, :not_found} ->
          case save_participant_binding(state, participant_id, channel, bridge_id, external_id) do
            :ok -> {:ok, :bound}
            {:error, _reason} = error -> error
          end
      end
    end
  end

  defp public_binding_result({:ok, :bound}), do: :ok
  defp public_binding_result({:error, _reason} = error), do: error

  defp resolve_room_binding_conflict({:error, reason} = error, state, channel, bridge_id, external_id) do
    if unique_constraint_error?(reason) do
      get_room_by_external_binding(state, channel, bridge_id, external_id)
    else
      error
    end
  end

  defp resolve_room_binding_conflict(result, _state, _channel, _bridge_id, _external_id), do: result

  defp unique_constraint_error?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:unique_violation, "23505"],
       do: true

  defp unique_constraint_error?(_reason), do: false

  defp find_room_binding(state, channel, bridge_id, external_id) do
    fetch_one(state, "room_binding", [
      {"channel", normalize_term(channel)},
      {"bridge_id", normalize_term(bridge_id)},
      {"external_id", normalize_term(external_id)}
    ])
  end

  defp find_participant_by_external_id(state, channel, external_id) do
    state
    |> list_records("participant", limit: 500)
    |> find_record(&participant_external_id_matches?(&1, %{channel: channel, external_id: external_id}))
  end

  defp find_participant_binding(state, channel, bridge_id, external_id) do
    with {:ok, binding} <- find_participant_binding_record(state, channel, bridge_id, external_id) do
      case get_participant(state, binding.participant_id) do
        {:ok, participant} ->
          {:ok, participant}

        {:error, :not_found} ->
          :ok = delete_participant_binding_record(state, channel, bridge_id, external_id)
          {:error, :not_found}
      end
    end
  end

  defp find_participant_binding_record(state, channel, bridge_id, external_id) do
    fetch_one(state, "participant_binding", [
      {"channel", normalize_term(channel)},
      {"bridge_id", normalize_term(bridge_id)},
      {"external_id", normalize_term(external_id)}
    ])
  end

  defp find_unclaimed_legacy_participant(state, channel, external_id) do
    case fetch_one(state, "participant_binding", [
           {"channel", normalize_term(channel)},
           {"external_id", normalize_term(external_id)}
         ]) do
      {:ok, _binding} -> {:error, :not_found}
      {:error, :not_found} -> find_participant_by_external_id(state, channel, external_id)
    end
  end

  defp save_participant_binding(state, participant_id, channel, bridge_id, external_id) do
    normalized_channel = normalize_term(channel)
    normalized_bridge_id = normalize_term(bridge_id)
    normalized_external_id = normalize_term(external_id)

    binding = %{
      participant_id: participant_id,
      channel: normalized_channel,
      bridge_id: normalized_bridge_id,
      external_id: normalized_external_id
    }

    id = participant_binding_id(normalized_channel, normalized_bridge_id, normalized_external_id)

    with :ok <-
           run(
             state,
             """
             INSERT INTO #{@table}
               (instance_id, kind, id, room_id, channel, bridge_id, external_id, payload)
             VALUES ($1, 'participant_binding', $2, $3, $4, $5, $6, $7)
             ON CONFLICT DO NOTHING
             """,
             [
               state.instance_id,
               id,
               participant_id,
               normalized_channel,
               normalized_bridge_id,
               normalized_external_id,
               :erlang.term_to_binary(binding)
             ],
             :bind_participant
           ),
         {:ok, stored_binding} <-
           find_participant_binding_record(state, channel, bridge_id, external_id) do
      if stored_binding.participant_id == participant_id do
        :ok
      else
        {:error, {:external_identity_conflict, stored_binding.participant_id}}
      end
    end
  end

  defp claim_legacy_or_create_participant(state, channel, bridge_id, external_id, attrs) do
    case find_unclaimed_legacy_participant(state, channel, external_id) do
      {:ok, participant} ->
        bind_or_resolve_participant(state, participant, channel, bridge_id, external_id, false)

      {:error, :not_found} ->
        participant = build_bound_participant(channel, external_id, attrs)

        with {:ok, participant} <- save_participant(state, participant) do
          bind_or_resolve_participant(state, participant, channel, bridge_id, external_id, true)
        end
    end
  end

  defp bind_or_resolve_participant(state, participant, channel, bridge_id, external_id, created?) do
    case do_bind_participant_external_id(state, participant.id, channel, bridge_id, external_id) do
      {:ok, :bound} ->
        {:ok, participant}

      {:error, {:external_identity_conflict, winner_id}} ->
        if created?, do: delete_participant(state, participant.id)
        get_participant(state, winner_id)

      {:error, _reason} = error ->
        if created?, do: delete_participant(state, participant.id)
        error
    end
  end

  defp delete_participant_binding_record(state, channel, bridge_id, external_id) do
    delete_record(
      state,
      "participant_binding",
      participant_binding_id(normalize_term(channel), normalize_term(bridge_id), normalize_term(external_id))
    )
  end

  defp participant_binding_id(channel, bridge_id, external_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({channel, bridge_id, external_id}))
    "participant_binding:" <> Base.url_encode64(digest, padding: false)
  end

  defp participant_matches?(participant, query) do
    id_matches?(participant.id, query) and
      name_matches?(participant_name(participant), query) and
      participant_external_id_matches?(participant, query)
  end

  defp room_matches?(state, room, query) do
    id_matches?(room.id, query) and
      name_matches?(room.name, query) and
      room_external_binding_matches?(state, room.id, query)
  end

  defp participant_external_id_matches?(participant, query) do
    channel = query_value(query, :channel)
    external_id = query_value(query, :external_id)

    cond do
      is_nil(channel) and is_nil(external_id) ->
        true

      is_nil(channel) or is_nil(external_id) ->
        false

      true ->
        expected_channel = normalize_term(channel)
        expected_external_id = normalize_term(external_id)

        Enum.any?(participant.external_ids || %{}, fn {key, value} ->
          normalize_term(key) == expected_channel and normalize_term(value) == expected_external_id
        end)
    end
  end

  defp room_external_binding_matches?(state, room_id, query) do
    channel = query_value(query, :channel)
    bridge_id = query_value(query, :bridge_id)
    external_id = query_value(query, :external_id)

    cond do
      is_nil(channel) and is_nil(bridge_id) and is_nil(external_id) ->
        true

      is_nil(channel) or is_nil(bridge_id) or is_nil(external_id) ->
        false

      true ->
        case find_room_binding(state, channel, bridge_id, external_id) do
          {:ok, binding} -> binding.room_id == room_id
          {:error, :not_found} -> false
          {:error, _reason} -> false
        end
    end
  end

  defp id_matches?(id, query) do
    case query_value(query, :id) do
      nil -> true
      expected_id -> normalize_term(id) == normalize_term(expected_id)
    end
  end

  defp name_matches?(name, query) do
    case query_value(query, :name) do
      nil -> true
      expected_name -> contains_ci?(name, expected_name)
    end
  end

  defp contains_ci?(value, expected) when is_binary(value) do
    String.contains?(String.downcase(value), String.downcase(normalize_term(expected)))
  end

  defp contains_ci?(_value, _expected), do: false

  defp participant_name(participant) do
    get_in(participant.identity || %{}, [:name]) || get_in(participant.identity || %{}, ["name"])
  end

  defp maybe_filter_enabled(configs, nil), do: configs
  defp maybe_filter_enabled(configs, value), do: Enum.filter(configs, &(&1.enabled == value))

  defp maybe_filter_subscription_status(subscriptions, nil), do: subscriptions

  defp maybe_filter_subscription_status(subscriptions, value) do
    Enum.filter(subscriptions, &(&1.status == value))
  end

  defp query_value(query, key) do
    Map.get(query, key) || Map.get(query, Atom.to_string(key))
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp build_bound_room(channel, bridge_id, external_id, attrs) do
    Room.new(
      Map.merge(attrs, %{
        external_bindings: %{
          channel => %{bridge_id => external_id}
        }
      })
    )
  end

  defp build_bound_participant(channel, external_id, attrs) do
    Participant.new(
      Map.merge(attrs, %{
        external_ids: %{channel => external_id}
      })
    )
  end

  defp where_clause(filters) do
    filters
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {{column, value}, index}, {clauses, params} ->
      {["#{column} = $#{index}" | clauses], params ++ [normalize_nullable(value)]}
    end)
    |> then(fn {clauses, params} -> {clauses |> Enum.reverse() |> Enum.join(" AND "), params} end)
  end

  defp decode_rows(rows) do
    Enum.map(rows, fn [payload] -> decode_payload(payload) end)
  end

  defp decode_payload(payload), do: :erlang.binary_to_term(payload, [:safe])

  defp run(state, sql, params, operation) do
    case query(state, sql, params, operation) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp query(state, sql, params, operation) do
    started_at = System.monotonic_time()

    try do
      result = Postgrex.query(state.conn, sql, params, timeout: state.query_timeout)
      emit_query(state, operation, started_at, result)
      result
    rescue
      exception ->
        result = {:error, exception}
        emit_query(state, operation, started_at, result)
        result
    catch
      kind, reason ->
        result = {:error, {kind, reason}}
        emit_query(state, operation, started_at, result)
        result
    end
  end

  defp emit_query(state, operation, started_at, result) do
    :telemetry.execute(
      [:jido_messaging, :persistence, :query],
      %{duration: System.monotonic_time() - started_at},
      %{
        adapter: __MODULE__,
        instance_id: state.instance_id,
        operation: operation,
        result: result_tag(result)
      }
    )
  end

  defp emit_health_check(state, started_at, result) do
    :telemetry.execute(
      [:jido_messaging, :persistence, :health_check],
      %{duration: System.monotonic_time() - started_at},
      %{
        adapter: __MODULE__,
        instance_id: state.instance_id,
        result: result_tag(result)
      }
    )
  end

  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, _value}), do: :ok
  defp result_tag({:error, _reason}), do: :error

  defp ingress_subscription_key(bridge_id, subscription_id) do
    "#{bridge_id}:#{subscription_id}"
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(value), do: to_string(value)

  defp normalize_nullable(nil), do: nil
  defp normalize_nullable(value), do: normalize_term(value)

  defp normalize_term(value) when is_binary(value), do: value
  defp normalize_term(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_term(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_term(value), do: inspect(value)

  defp normalize_instance_id(value) do
    case value |> to_string() |> String.trim() do
      "" -> @default_instance_id
      instance_id -> instance_id
    end
  end
end
