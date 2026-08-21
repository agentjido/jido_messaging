defmodule Jido.Messaging.Persistence.SQLite do
  @moduledoc """
  Durable SQLite persistence adapter for `Jido.Messaging`.

  This adapter stores canonical messaging records directly in SQLite. It is
  intentionally simple: each record is serialized as an Erlang term with a small
  set of indexed columns for common messaging lookups. It does not maintain an
  implicit ETS cache; applications that need caching can layer that separately.

  ## Options

    * `:path` - SQLite database path. Defaults to `"data/jido_messaging.sqlite3"`.
    * `:instance_id` - stable namespace for all records. Direct adapter use
      defaults to `"default"`. A `Jido.Messaging` runtime supplies its module
      name when this option is absent.

  """

  @behaviour Jido.Messaging.Persistence
  @behaviour Jido.Messaging.Directory

  alias Exqlite.Sqlite3
  alias Jido.Chat.{Participant, Room}

  alias Jido.Messaging.{
    BridgeConfig,
    IngressSubscription,
    Message,
    RoomBinding,
    RoutingPolicy,
    Thread
  }

  @table "jido_messaging_records"
  @default_instance_id "default"

  defstruct [:db, :path, :instance_id]

  @type t :: %__MODULE__{
          db: reference(),
          path: String.t(),
          instance_id: String.t()
        }

  @impl true
  def init(opts) do
    path = opts |> Keyword.get(:path, "data/jido_messaging.sqlite3") |> to_string()
    instance_id = opts |> Keyword.get(:instance_id, @default_instance_id) |> normalize_instance_id()
    :ok = ensure_parent_dir(path)

    with {:ok, db} <- Sqlite3.open(path) do
      :ok = Sqlite3.set_busy_timeout(db, 5_000)

      case with_migration_lock(path, fn -> migrate(db, instance_id) end) do
        :ok ->
          {:ok, %__MODULE__{db: db, path: path, instance_id: instance_id}}

        {:error, _reason} = error ->
          _ = Sqlite3.close(db)
          error
      end
    end
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
      state.db,
      """
      DELETE FROM #{@table}
      WHERE instance_id = ?1
        AND ((kind = 'room' AND id = ?2)
         OR (kind IN ('message', 'thread', 'room_binding', 'routing_policy') AND room_id = ?2))
      """,
      [state.instance_id, room_id]
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
    delete_record(state, "participant", participant_id)
  end

  @impl true
  def save_message(state, %Message{} = message) do
    metadata = message.metadata || %{}

    persist(state, "message", message.id, message,
      room_id: message.room_id,
      thread_id: message.thread_id,
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

  defp cursor_direction(opts) do
    case {Keyword.get(opts, :before), Keyword.get(opts, :after)} do
      {nil, nil} -> {:ok, :none}
      {before, nil} when is_binary(before) and before != "" -> {:ok, {:before, before}}
      {nil, after_cursor} when is_binary(after_cursor) and after_cursor != "" -> {:ok, {:after, after_cursor}}
      {_before, _after_cursor} -> {:error, :invalid_cursor_options}
    end
  end

  defp message_scope(room_id, thread_id) when is_binary(thread_id) do
    {"kind = ?1 AND room_id = ?2 AND thread_id = ?3", ["message", room_id, thread_id]}
  end

  defp message_scope(room_id, _thread_id), do: {"kind = ?1 AND room_id = ?2", ["message", room_id]}

  defp resolve_message_cursor(_state, _where, _params, :none), do: {:ok, nil}

  defp resolve_message_cursor(state, where, params, {_direction, cursor_id}) do
    cursor_param = length(params) + 1

    with {:ok, rows} <-
           query_all(
             state.db,
             "SELECT COALESCE(inserted_at, ''), id FROM #{@table} WHERE #{where} AND id = ?#{cursor_param} LIMIT 1",
             params ++ [cursor_id]
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
      "#{where} AND (COALESCE(inserted_at, '') #{operator} ?#{timestamp_param} OR " <>
        "(COALESCE(inserted_at, '') = ?#{timestamp_param} AND id #{operator} ?#{id_param}))"

    order = if direction == :before, do: "DESC", else: "ASC"
    {cursor_where, params ++ [inserted_at, id], order, direction == :before}
  end

  defp query_message_page(state, where, params, order, limit) do
    query_all(
      state.db,
      """
      SELECT payload
      FROM #{@table}
      WHERE #{where}
      ORDER BY COALESCE(inserted_at, '') #{order}, id #{order}
      LIMIT ?#{length(params) + 1}
      """,
      params ++ [limit]
    )
  end

  @impl true
  def delete_message(state, message_id) do
    delete_record(state, "message", message_id)
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
      "kind = ?1 AND room_id = ?2",
      ["thread", room_id],
      order: "inserted_at ASC, id ASC",
      limit: limit
    )
  end

  @impl true
  def get_or_create_room_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    case get_room_by_external_binding(state, channel, bridge_id, external_id) do
      {:ok, room} ->
        {:ok, room}

      {:error, :not_found} ->
        room = build_bound_room(channel, bridge_id, external_id, attrs)

        with {:ok, room} <- save_room(state, room),
             {:ok, _binding} <- create_room_binding(state, room.id, channel, bridge_id, external_id, %{}) do
          {:ok, room}
        end
    end
  end

  @impl true
  def get_or_create_participant_by_external_id(state, channel, external_id, attrs) do
    case find_participant_by_external_id(state, channel, external_id) do
      {:ok, participant} ->
        {:ok, participant}

      {:error, :not_found} ->
        participant = build_bound_participant(channel, external_id, attrs)
        save_participant(state, participant)
    end
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
      "kind = ?1 AND room_id = ?2",
      ["room_binding", room_id],
      order: "inserted_at ASC, id ASC",
      limit: 500
    )
  end

  @impl true
  def delete_room_binding(state, binding_id) do
    case fetch_record(state, "room_binding", binding_id) do
      {:ok, _binding} -> delete_record(state, "room_binding", binding_id)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
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
    persist(state, "bridge_config", bridge_config.id, bridge_config, inserted_at: bridge_config.inserted_at)
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
    case fetch_record(state, "bridge_config", bridge_id) do
      {:ok, _config} -> delete_record(state, "bridge_config", bridge_id)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
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
             "kind = ?1 AND room_id = ?2",
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

    case fetch_record(state, "ingress_subscription", id) do
      {:ok, _subscription} -> delete_record(state, "ingress_subscription", id)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def save_routing_policy(state, %RoutingPolicy{} = routing_policy) do
    persist(state, "routing_policy", routing_policy.room_id, routing_policy, room_id: routing_policy.room_id)
  end

  @impl true
  def get_routing_policy(state, room_id), do: fetch_record(state, "routing_policy", room_id)

  @impl true
  def delete_routing_policy(state, room_id) do
    case fetch_record(state, "routing_policy", room_id) do
      {:ok, _policy} -> delete_record(state, "routing_policy", room_id)
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_parent_dir(":memory:"), do: :ok

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp migrate(db, instance_id) do
    with :ok <-
           exec(db, """
           PRAGMA journal_mode = WAL;
           PRAGMA synchronous = NORMAL;
           """),
         {:ok, columns} <- query_all(db, "PRAGMA table_info(#{@table})", []) do
      cond do
        columns == [] ->
          with :ok <- exec(db, create_table_sql()), do: create_indexes(db)

        Enum.any?(columns, fn [_cid, name | _rest] -> name == "instance_id" end) ->
          create_indexes(db)

        true ->
          migrate_legacy_table(db, instance_id)
      end
    end
  end

  defp with_migration_lock(path, fun) do
    resource = {__MODULE__, Path.expand(path), :schema_migration}

    case :global.trans({resource, self()}, fun) do
      :aborted -> {:error, :migration_lock_aborted}
      result -> result
    end
  end

  defp migrate_legacy_table(db, instance_id) do
    result =
      with :ok <- exec(db, "BEGIN IMMEDIATE"),
           {:ok, columns} <- query_all(db, "PRAGMA table_info(#{@table})", []),
           :ok <- migrate_legacy_table_locked(db, columns, instance_id),
           :ok <- exec(db, "COMMIT") do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ = exec(db, "ROLLBACK")
        error
    end
  end

  defp migrate_legacy_table_locked(db, columns, instance_id) do
    if Enum.any?(columns, fn [_cid, name | _rest] -> name == "instance_id" end) do
      create_indexes(db)
    else
      with :ok <- exec(db, "ALTER TABLE #{@table} RENAME TO #{@table}_legacy"),
           :ok <- exec(db, create_table_sql()),
           :ok <-
             run(
               db,
               """
               INSERT INTO #{@table}
                 (instance_id, kind, id, room_id, thread_id, inserted_at, channel, bridge_id, external_id, payload)
               SELECT ?1, kind, id, room_id, thread_id, inserted_at, channel, bridge_id, external_id, payload
               FROM #{@table}_legacy
               """,
               [instance_id]
             ),
           :ok <- exec(db, "DROP TABLE #{@table}_legacy") do
        create_indexes(db)
      end
    end
  end

  defp create_table_sql do
    """

    CREATE TABLE IF NOT EXISTS #{@table} (
      instance_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      id TEXT NOT NULL,
      room_id TEXT,
      thread_id TEXT,
      inserted_at TEXT,
      channel TEXT,
      bridge_id TEXT,
      external_id TEXT,
      payload BLOB NOT NULL,
      PRIMARY KEY (instance_id, kind, id)
    );
    """
  end

  defp create_indexes(db) do
    exec(db, """
    CREATE INDEX IF NOT EXISTS #{@table}_room_idx
      ON #{@table} (instance_id, kind, room_id);

    CREATE INDEX IF NOT EXISTS #{@table}_thread_idx
      ON #{@table} (instance_id, kind, thread_id);

    CREATE INDEX IF NOT EXISTS #{@table}_external_idx
      ON #{@table} (instance_id, kind, channel, bridge_id, external_id);
    """)
  end

  defp persist(state, kind, id, record, opts \\ []) do
    with :ok <- upsert_record(state, kind, id, record, opts) do
      {:ok, record}
    end
  end

  defp upsert_record(state, kind, id, record, opts) do
    run(
      state.db,
      """
      INSERT INTO #{@table}
        (instance_id, kind, id, room_id, thread_id, inserted_at, channel, bridge_id, external_id, payload)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      ON CONFLICT(instance_id, kind, id) DO UPDATE SET
        room_id = excluded.room_id,
        thread_id = excluded.thread_id,
        inserted_at = excluded.inserted_at,
        channel = excluded.channel,
        bridge_id = excluded.bridge_id,
        external_id = excluded.external_id,
        payload = excluded.payload
      """,
      [
        state.instance_id,
        kind,
        id,
        Keyword.get(opts, :room_id),
        Keyword.get(opts, :thread_id),
        format_datetime(Keyword.get(opts, :inserted_at)),
        opts |> Keyword.get(:channel) |> normalize_nullable(),
        opts |> Keyword.get(:bridge_id) |> normalize_nullable(),
        opts |> Keyword.get(:external_id) |> normalize_nullable(),
        {:blob, :erlang.term_to_binary(record)}
      ]
    )
  end

  defp fetch_record(state, kind, id) do
    fetch_one(state, kind, [{"id", id}])
  end

  defp fetch_one(state, kind, filters) do
    {where, params} = where_clause([{"instance_id", state.instance_id}, {"kind", kind} | filters])

    with {:ok, rows} <-
           query_all(
             state.db,
             """
             SELECT payload
             FROM #{@table}
             WHERE #{where}
             LIMIT 1
             """,
             params
           ) do
      case decode_rows(rows) do
        [record] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    end
  end

  defp list_records(state, kind, opts, sql_opts \\ []) do
    query_records(state, "kind = ?1", [kind], Keyword.merge(sql_opts, limit: Keyword.get(opts, :limit, 100)))
  end

  defp query_records(state, where, params, opts) do
    limit = Keyword.fetch!(opts, :limit)
    order = Keyword.get(opts, :order, "inserted_at ASC, id ASC")
    {where, params} = with_instance_scope(state, where, params)

    with {:ok, rows} <-
           query_all(
             state.db,
             """
             SELECT payload
             FROM #{@table}
             WHERE #{where}
             ORDER BY #{order}
             LIMIT ?#{length(params) + 1}
             """,
             params ++ [limit]
           ) do
      {:ok, decode_rows(rows)}
    end
  end

  defp delete_record(state, kind, id) do
    run(
      state.db,
      "DELETE FROM #{@table} WHERE instance_id = ?1 AND kind = ?2 AND id = ?3",
      [state.instance_id, kind, id]
    )
  end

  defp with_instance_scope(state, where, params) do
    instance_param = length(params) + 1
    {"(#{where}) AND instance_id = ?#{instance_param}", params ++ [state.instance_id]}
  end

  defp find_record({:ok, records}, predicate) do
    case Enum.find(records, predicate) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp find_record({:error, _reason} = error, _predicate), do: error

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
      {["#{column} = ?#{index}" | clauses], params ++ [normalize_nullable(value)]}
    end)
    |> then(fn {clauses, params} -> {clauses |> Enum.reverse() |> Enum.join(" AND "), params} end)
  end

  defp decode_rows(rows) do
    Enum.map(rows, fn [payload] -> :erlang.binary_to_term(payload) end)
  end

  defp exec(db, sql) do
    case Sqlite3.execute(db, sql) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      with_prepared_statement(db, statement, fn ->
        with :ok <- Sqlite3.bind(statement, params) do
          case Sqlite3.step(db, statement) do
            :done -> :ok
            {:row, _row} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      end)
    end
  end

  defp query_all(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      with_prepared_statement(db, statement, fn ->
        with :ok <- Sqlite3.bind(statement, params) do
          {:ok, collect_rows(db, statement, [])}
        end
      end)
    end
  end

  defp with_prepared_statement(db, statement, fun) do
    try do
      fun.()
    rescue
      exception -> {:error, exception}
    catch
      {:sqlite_error, reason} -> {:error, reason}
    after
      _ = Sqlite3.release(db, statement)
    end
  end

  defp collect_rows(db, statement, rows) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> collect_rows(db, statement, [row | rows])
      :done -> Enum.reverse(rows)
      {:error, reason} -> throw({:sqlite_error, reason})
    end
  end

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
