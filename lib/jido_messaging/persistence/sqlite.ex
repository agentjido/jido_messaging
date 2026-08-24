defmodule Jido.Messaging.Persistence.SQLite do
  @moduledoc """
  Lightweight SQLite persistence adapter for `Jido.Messaging`.

  Use this adapter for demos, local development, and tests. Use
  `Jido.Messaging.Persistence.Postgres` for production deployments that need a
  connection pool and concurrent writers.

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
    AgentDirectoryProjection,
    ActivityPage,
    AgentMessagingEndpoint,
    AgentThreadRoute,
    AuthorizationScope,
    BridgeConfig,
    ExternalIdentityBinding,
    Grant,
    IdentityAssertionUse,
    IdentityCredential,
    IngressSubscription,
    JidokaDelegationEvent,
    InvocationPolicy,
    Membership,
    Message,
    MessagingActivityEntry,
    Principal,
    RoomBinding,
    RoomMembership,
    RoutingPolicy,
    Thread,
    ThreadContinuityLink
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
  def capabilities(_state), do: [:durable, :transactions]

  @impl true
  def health_check(state) do
    case query_all(state.db, "SELECT 1", []) do
      {:ok, [[1]]} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def close(state) do
    case Sqlite3.close(state.db) do
      :ok -> :ok
      {:error, _reason} -> :ok
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
         OR (kind IN (
           'message',
           'thread',
           'room_binding',
           'routing_policy',
           'jidoka_delegation_event',
           'jidoka_delegation_cancellation',
           'thread_continuity_link',
           'messaging_activity',
           'membership',
           'principal_grant',
           'invocation_policy',
           'room_membership',
           'agent_thread_route'
         ) AND room_id = ?2))
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
    with :ok <- validate_existing_principal(state, participant),
         {:ok, participant} <- persist(state, "participant", participant.id, participant),
         {:ok, _principal} <- ensure_principal(state, participant) do
      {:ok, participant}
    end
  end

  @impl true
  def get_participant(state, participant_id), do: fetch_record(state, "participant", participant_id)

  @impl true
  def delete_participant(state, participant_id) do
    run(
      state.db,
      """
      DELETE FROM #{@table}
      WHERE instance_id = ?1
        AND ((kind = 'participant' AND id = ?2)
          OR (kind = 'participant_binding' AND room_id = ?2)
          OR (kind = 'thread_continuity_link' AND sender_id = ?2)
          OR (kind = 'agent_directory_projection' AND sender_id = ?2)
          OR (kind = 'messaging_activity' AND sender_id = ?2)
          OR (kind = 'identity_assertion' AND room_id IN (
            SELECT id FROM #{@table}
            WHERE instance_id = ?1 AND kind = 'identity_credential'
              AND (sender_id = ?2 OR room_id = ?2)
          ))
          OR (kind = 'identity_credential' AND (sender_id = ?2 OR room_id = ?2))
          OR (kind IN ('membership', 'principal_grant', 'invocation_policy') AND sender_id = ?2))
      """,
      [state.instance_id, participant_id]
    )

    with :ok <-
           run(
             state.db,
             """
             DELETE FROM #{@table}
             WHERE instance_id = ?1
               AND kind = 'agent_thread_route'
               AND external_id IN (
                 SELECT id
                 FROM #{@table}
                 WHERE instance_id = ?1
                   AND kind = 'agent_endpoint'
                   AND sender_id = ?2
               )
             """,
             [state.instance_id, participant_id]
           ) do
      run(
        state.db,
        """
        DELETE FROM #{@table}
        WHERE instance_id = ?1
          AND ((kind = 'participant' AND id = ?2)
            OR (kind = 'principal' AND id = ?2)
            OR (kind = 'participant_binding' AND room_id = ?2)
            OR (kind = 'agent_endpoint' AND sender_id = ?2)
            OR (kind = 'room_membership' AND sender_id = ?2))
        """,
        [state.instance_id, participant_id]
      )
    end
  end

  # Canonical identity operations

  @impl true
  def save_principal(state, %Principal{} = principal) do
    with {:ok, participant} <- get_participant(state, principal.participant_id),
         :ok <- validate_principal_projection(principal, participant),
         :ok <- validate_principal_controller(state, principal) do
      persist(state, "principal", principal.id, principal, room_id: principal.participant_id)
    end
  end

  @impl true
  def get_principal(state, principal_id), do: fetch_record(state, "principal", principal_id)

  @impl true
  def save_external_identity_binding(state, %ExternalIdentityBinding{} = binding) do
    participant_binding_lock(state, binding.channel, binding.external_id, fn ->
      transaction(state, fn transaction_state ->
        do_save_external_identity_binding(transaction_state, binding)
      end)
    end)
  end

  @impl true
  def get_external_identity_binding(state, binding_id) do
    state
    |> fetch_record("participant_binding", binding_id)
    |> normalize_external_identity_binding_result()
  end

  @impl true
  def get_external_identity_binding(state, channel, bridge_id, external_id) do
    find_participant_binding_record(state, channel, bridge_id, external_id)
  end

  @impl true
  def list_external_identity_bindings(state, principal_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, records} <-
           query_records(
             state,
             "kind = ?1 AND room_id = ?2",
             ["participant_binding", principal_id],
             limit: limit,
             order: "inserted_at ASC, id ASC"
           ) do
      {:ok, Enum.map(records, &normalize_external_identity_binding/1)}
    end
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

  # Messaging activity projection operations

  @impl true
  def save_messaging_activity(state, %MessagingActivityEntry{} = entry) do
    binding_lock(state, {:messaging_activity, entry.id}, fn ->
      transaction(state, fn transaction_state ->
        case get_messaging_activity(transaction_state, entry.id) do
          {:error, :not_found} -> persist_messaging_activity(transaction_state, entry)
          {:ok, stored} -> revise_sqlite_messaging_activity(transaction_state, stored, entry)
          {:error, _reason} = error -> error
        end
      end)
    end)
  end

  @impl true
  def get_messaging_activity(state, activity_id) when is_binary(activity_id),
    do: fetch_record(state, "messaging_activity", activity_id)

  @impl true
  def get_principal_activity(state, principal_id, room_ids, opts \\ [])

  def get_principal_activity(_state, _principal_id, [], opts), do: ActivityPage.paginate([], opts)

  def get_principal_activity(state, principal_id, room_ids, opts)
      when is_binary(principal_id) and is_list(room_ids) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)

    if is_integer(limit) and limit > 0 do
      query_principal_records(state, "messaging_activity", principal_id, room_ids, opts, min(limit, 500))
    else
      {:error, :invalid_limit}
    end
  end

  defp query_participant_messages(state, participant_id, room_ids, opts, limit) do
    query_principal_records(state, "message", participant_id, room_ids, opts, limit)
  end

  defp query_principal_records(state, kind, participant_id, room_ids, opts, limit) do
    room_placeholders =
      room_ids
      |> Enum.with_index(3)
      |> Enum.map_join(", ", fn {_room_id, index} -> "?#{index}" end)

    where = "kind = ?1 AND sender_id = ?2 AND room_id IN (#{room_placeholders})"
    params = [kind, participant_id | room_ids]
    {where, params} = with_instance_scope(state, where, params)

    case participant_cursor_direction(opts) do
      :none ->
        query_participant_page(state.db, where, params, "DESC", limit, true)

      {:before, cursor_id} ->
        with {:ok, {inserted_at, id}} <- participant_cursor(state.db, where, params, cursor_id) do
          timestamp_param = length(params) + 1
          id_param = timestamp_param + 1

          cursor_where =
            "#{where} AND (COALESCE(inserted_at, '') < ?#{timestamp_param} OR " <>
              "(COALESCE(inserted_at, '') = ?#{timestamp_param} AND id < ?#{id_param}))"

          query_participant_page(state.db, cursor_where, params ++ [inserted_at, id], "DESC", limit, true)
        end

      {:after, cursor_id} ->
        with {:ok, {inserted_at, id}} <- participant_cursor(state.db, where, params, cursor_id) do
          timestamp_param = length(params) + 1
          id_param = timestamp_param + 1

          cursor_where =
            "#{where} AND (COALESCE(inserted_at, '') > ?#{timestamp_param} OR " <>
              "(COALESCE(inserted_at, '') = ?#{timestamp_param} AND id > ?#{id_param}))"

          query_participant_page(state.db, cursor_where, params ++ [inserted_at, id], "ASC", limit, false)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp participant_cursor(db, where, params, cursor_id) do
    cursor_param = length(params) + 1

    with {:ok, rows} <-
           query_all(
             db,
             """
             SELECT COALESCE(inserted_at, ''), id
             FROM #{@table}
             WHERE #{where} AND id = ?#{cursor_param}
             LIMIT 1
             """,
             params ++ [cursor_id]
           ) do
      case rows do
        [[inserted_at, id]] -> {:ok, {inserted_at, id}}
        [] -> {:error, :cursor_not_found}
      end
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

  defp query_participant_page(db, where, params, direction, limit, reverse?) do
    limit_param = length(params) + 1

    with {:ok, rows} <-
           query_all(
             db,
             """
             SELECT payload
             FROM #{@table}
             WHERE #{where}
             ORDER BY COALESCE(inserted_at, '') #{direction}, id #{direction}
             LIMIT ?#{limit_param}
             """,
             params ++ [limit]
           ) do
      messages = decode_rows(rows)
      {:ok, if(reverse?, do: Enum.reverse(messages), else: messages)}
    end
  end

  defp participant_cursor_direction(opts) do
    case {Keyword.get(opts, :before), Keyword.get(opts, :after)} do
      {nil, nil} -> :none
      {before, nil} when is_binary(before) and before != "" -> {:before, before}
      {nil, after_cursor} when is_binary(after_cursor) and after_cursor != "" -> {:after, after_cursor}
      {_before, _after_cursor} -> {:error, :invalid_cursor_options}
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
      "kind = ?1 AND room_id = ?2",
      ["thread", room_id],
      order: "inserted_at ASC, id ASC",
      limit: limit
    )
  end

  # Jidoka delegation transport records

  @impl true
  def save_jidoka_delegation_event(state, %JidokaDelegationEvent{} = incoming) do
    binding_lock(state, :jidoka_delegation, fn ->
      transaction(state, fn transaction_state ->
        case optional_jidoka_delegation_event(transaction_state, incoming.id) do
          {:ok, %JidokaDelegationEvent{} = stored} ->
            with :ok <- ensure_delegation_not_cancelled(transaction_state, incoming) do
              if JidokaDelegationEvent.equivalent?(stored, incoming) do
                {:ok, stored}
              else
                {:error, :jidoka_delegation_event_conflict}
              end
            end

          {:ok, nil} ->
            with :ok <- ensure_delegation_not_cancelled(transaction_state, incoming),
                 :ok <- ensure_delegation_transport_available(transaction_state, incoming),
                 :ok <- ensure_delegation_emission_available(transaction_state, incoming),
                 {:ok, saved} <- persist_jidoka_delegation_event(transaction_state, incoming),
                 :ok <- maybe_mark_delegation_cancelled(transaction_state, incoming) do
              {:ok, saved}
            end

          {:error, _reason} = error ->
            error
        end
      end)
    end)
  end

  # Jidoka continuity correlation

  @impl true
  def save_thread_continuity_link(state, %ThreadContinuityLink{} = incoming) do
    binding_lock(state, :thread_continuity, fn ->
      transaction(state, fn transaction_state ->
        with {:ok, stored} <- optional_continuity_link(transaction_state, incoming.thread_id),
             {:ok, accepted, operation} <-
               ThreadContinuityLink.prepare_save(stored, incoming),
             :ok <-
               ensure_continuity_session_available(transaction_state, accepted, operation) do
          persist_continuity_link(transaction_state, accepted)
        end
      end)
    end)
  end

  # Principal authorization operations

  @impl true
  def save_membership(state, %Membership{} = membership) do
    binding_lock(state, {:membership, membership.room_id, membership.principal_id}, fn ->
      transaction(state, fn transaction_state ->
        with :ok <-
               validate_sqlite_revision(
                 transaction_state,
                 "membership",
                 membership,
                 &membership_identity?/2
               ),
             :ok <- validate_sqlite_membership_scope(transaction_state, membership) do
          persist(transaction_state, "membership", membership.id, membership,
            room_id: membership.room_id,
            sender_id: membership.principal_id,
            inserted_at: membership.inserted_at,
            external_id: membership.principal_id
          )
        end
      end)
    end)
  end

  # Agent messaging endpoint operations

  @impl true
  def save_agent_messaging_endpoint(state, %AgentMessagingEndpoint{} = endpoint) do
    binding_lock(state, :agent_endpoint, fn ->
      transaction(state, fn transaction_state ->
        do_save_agent_messaging_endpoint(transaction_state, endpoint)
      end)
    end)
  end

  @impl true
  def get_membership(state, membership_id), do: fetch_record(state, "membership", membership_id)

  @impl true
  def get_membership_by_scope(state, room_id, principal_id) do
    fetch_one(state, "membership", [{"room_id", room_id}, {"sender_id", principal_id}])
  end

  @impl true
  def list_memberships(state, room_id, opts \\ []) do
    with {:ok, records} <-
           query_records(
             state,
             "kind = ?1 AND room_id = ?2",
             ["membership", room_id],
             order: "inserted_at ASC, id ASC",
             limit: 500
           ) do
      {:ok,
       records
       |> filter_authorization_record(:principal_id, Keyword.get(opts, :principal_id))
       |> filter_authorization_record(:status, Keyword.get(opts, :status))
       |> take_authorization_records(opts)}
    end
  end

  @impl true
  def get_agent_messaging_endpoint(state, endpoint_id),
    do: fetch_record(state, "agent_endpoint", endpoint_id)

  @impl true
  def get_agent_messaging_endpoint_by_ref(state, jidoka_agent_id) do
    fetch_one(state, "agent_endpoint", [{"external_id", normalize_term(jidoka_agent_id)}])
  end

  @impl true
  def list_agent_messaging_endpoints(state, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, endpoints} <- list_records(state, "agent_endpoint", limit: 500, order: "inserted_at ASC, id ASC") do
      endpoints =
        endpoints
        |> maybe_filter_record(:principal_id, Keyword.get(opts, :principal_id))
        |> maybe_filter_record(:status, Keyword.get(opts, :status))
        |> maybe_filter_record(:availability, Keyword.get(opts, :availability))
        |> Enum.take(limit)

      {:ok, endpoints}
    end
  end

  @impl true
  def save_principal_grant(state, %Grant{} = grant) do
    binding_lock(state, {:principal_grant, grant.id}, fn ->
      transaction(state, fn transaction_state ->
        with :ok <-
               validate_sqlite_revision(
                 transaction_state,
                 "principal_grant",
                 grant,
                 &grant_identity?/2
               ) do
          persist(transaction_state, "principal_grant", grant.id, grant,
            room_id: grant.scope.room_id,
            thread_id: grant.scope.thread_id,
            sender_id: grant.principal_id,
            inserted_at: grant.inserted_at,
            bridge_id: grant.scope.bridge_id,
            external_id: AuthorizationScope.key(grant.scope)
          )
        end
      end)
    end)
  end

  @impl true
  def get_jidoka_delegation_event(state, event_id) when is_binary(event_id) do
    fetch_record(state, "jidoka_delegation_event", event_id)
  end

  @impl true
  def get_thread_continuity_link(state, thread_id) when is_binary(thread_id) do
    fetch_one(state, "thread_continuity_link", [{"thread_id", thread_id}])
  end

  @impl true
  def save_room_membership(state, %RoomMembership{} = membership) do
    binding_lock(state, {:room_membership, membership.room_id, membership.endpoint_id}, fn ->
      transaction(state, fn transaction_state ->
        do_save_room_membership(transaction_state, membership)
      end)
    end)
  end

  @impl true
  def get_principal_grant(state, grant_id), do: fetch_record(state, "principal_grant", grant_id)

  @impl true
  def list_principal_grants(state, principal_id, opts \\ []) do
    with {:ok, records} <-
           query_records(
             state,
             "kind = ?1 AND sender_id = ?2",
             ["principal_grant", principal_id],
             order: "inserted_at ASC, id ASC",
             limit: 501
           ) do
      {:ok,
       records
       |> filter_authorization_record(:status, Keyword.get(opts, :status))
       |> filter_authorization_action(Keyword.get(opts, :action))
       |> take_authorization_records(opts)}
    end
  end

  @impl true
  def save_invocation_policy(state, %InvocationPolicy{} = policy) do
    scope_key = AuthorizationScope.key(policy.scope)

    binding_lock(state, {:invocation_policy, policy.target_principal_id, scope_key}, fn ->
      transaction(state, fn transaction_state ->
        with :ok <-
               validate_sqlite_revision(
                 transaction_state,
                 "invocation_policy",
                 policy,
                 &policy_identity?/2
               ),
             :ok <- validate_sqlite_policy_scope(transaction_state, policy, scope_key) do
          persist(transaction_state, "invocation_policy", policy.id, policy,
            room_id: policy.scope.room_id,
            thread_id: policy.scope.thread_id,
            sender_id: policy.target_principal_id,
            inserted_at: policy.inserted_at,
            bridge_id: policy.scope.bridge_id,
            external_id: scope_key
          )
        end
      end)
    end)
  end

  @impl true
  def get_invocation_policy(state, policy_id),
    do: fetch_record(state, "invocation_policy", policy_id)

  @impl true
  def get_invocation_policy_by_scope(state, target_principal_id, scope_key) do
    fetch_one(state, "invocation_policy", [
      {"sender_id", target_principal_id},
      {"external_id", scope_key}
    ])
  end

  @impl true
  def get_room_membership(state, membership_id),
    do: fetch_record(state, "room_membership", membership_id)

  @impl true
  def get_room_membership(state, room_id, endpoint_id) do
    fetch_one(state, "room_membership", [
      {"room_id", room_id},
      {"external_id", endpoint_id}
    ])
  end

  @impl true
  def list_invocation_policies(state, target_principal_id, opts \\ []) do
    with {:ok, records} <-
           query_records(
             state,
             "kind = ?1 AND sender_id = ?2",
             ["invocation_policy", target_principal_id],
             order: "inserted_at ASC, id ASC",
             limit: 501
           ) do
      {:ok,
       records
       |> filter_authorization_record(:status, Keyword.get(opts, :status))
       |> take_authorization_records(opts)}
    end
  end

  @impl true
  def list_room_memberships(state, room_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, memberships} <-
           query_records(
             state,
             "kind = ?1 AND room_id = ?2",
             ["room_membership", room_id],
             order: "inserted_at ASC, id ASC",
             limit: 500
           ) do
      memberships =
        memberships
        |> maybe_filter_record(:endpoint_id, Keyword.get(opts, :endpoint_id))
        |> maybe_filter_record(:principal_id, Keyword.get(opts, :principal_id))
        |> maybe_filter_record(:status, Keyword.get(opts, :status))
        |> Enum.take(limit)

      {:ok, memberships}
    end
  end

  @impl true
  def save_agent_thread_route(state, %AgentThreadRoute{} = route) do
    binding_lock(state, {:agent_thread_route, route.thread_id}, fn ->
      transaction(state, fn transaction_state ->
        case get_agent_thread_route(transaction_state, route.thread_id) do
          {:ok, %AgentThreadRoute{id: route_id}} when route_id != route.id ->
            {:error, {:agent_thread_route_conflict, route_id}}

          {:ok, _existing} ->
            persist_agent_thread_route(transaction_state, route)

          {:error, :not_found} ->
            persist_agent_thread_route(transaction_state, route)
        end
      end)
    end)
  end

  @impl true
  def get_agent_thread_route(state, thread_id) do
    fetch_one(state, "agent_thread_route", [{"thread_id", thread_id}])
  end

  @impl true
  def list_agent_thread_routes(state, endpoint_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    with {:ok, routes} <-
           query_records(
             state,
             "kind = ?1 AND external_id = ?2",
             ["agent_thread_route", endpoint_id],
             order: "inserted_at ASC, id ASC",
             limit: 500
           ) do
      routes =
        routes
        |> maybe_filter_record(:room_id, Keyword.get(opts, :room_id))
        |> maybe_filter_record(:status, Keyword.get(opts, :status))
        |> Enum.take(limit)

      {:ok, routes}
    end
  end

  @impl true
  def get_or_create_room_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    binding_lock(state, {:room, channel, bridge_id, external_id}, fn ->
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
    end)
    |> resolve_room_binding_conflict(state, channel, bridge_id, external_id)
  end

  @impl true
  def get_or_create_participant_by_external_id(state, channel, external_id, attrs) do
    get_or_create_participant_by_external_binding(state, channel, "default", external_id, attrs)
  end

  @impl true
  def get_or_create_participant_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    participant_binding_lock(state, channel, external_id, fn ->
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

          {:error, :external_identity_revoked} = error ->
            error
        end
      end)
    end)
  end

  @impl true
  def bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) do
    participant_binding_lock(state, channel, external_id, fn ->
      transaction(state, fn transaction_state ->
        do_bind_participant_external_id(
          transaction_state,
          participant_id,
          channel,
          bridge_id,
          external_id
        )
      end)
    end)
    |> public_binding_result()
  end

  defp do_bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) do
    with {:ok, participant} <- get_participant(state, participant_id),
         {:ok, _principal} <- ensure_principal(state, participant) do
      case find_participant_binding_record(state, channel, bridge_id, external_id) do
        {:ok, %{participant_id: ^participant_id, status: :revoked}} ->
          {:error, :external_identity_revoked}

        {:ok, %{participant_id: ^participant_id}} ->
          {:ok, :bound}

        {:ok, %{participant_id: existing_participant_id}} ->
          case get_participant(state, existing_participant_id) do
            {:ok, _participant} ->
              {:error, {:external_identity_conflict, existing_participant_id}}

            {:error, :not_found} ->
              :ok = delete_participant_binding_record(state, channel, bridge_id, external_id)

              do_bind_participant_external_id(
                state,
                participant_id,
                channel,
                bridge_id,
                external_id
              )
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
        |> Enum.filter(&participant_matches?(&1, state, query))
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

  def directory_search(state, :agent, query, opts) when is_map(query) do
    case Keyword.fetch(opts, :scope) do
      {:ok, %Jido.Messaging.AgentDirectoryScope{} = scope} ->
        with {:ok, projections} <-
               list_agent_directory_projections(state,
                 endpoint_ids: Map.keys(scope.endpoint_principals),
                 limit: 500
               ) do
          Jido.Messaging.AgentDirectory.filter_projections(
            projections,
            query,
            scope,
            Keyword.delete(opts, :scope)
          )
        end

      _other ->
        {:error, :agent_directory_scope_required}
    end
  end

  def directory_search(_state, target, _query, _opts) do
    {:error, {:invalid_directory_target, target}}
  end

  # Jidoka agent directory projection operations

  @impl true
  def save_agent_directory_projection(state, %AgentDirectoryProjection{} = projection) do
    binding_lock(state, {:agent_directory_projection, projection.id}, fn ->
      transaction(state, fn transaction_state ->
        with {:ok, accepted} <- validate_sqlite_agent_directory_revision(transaction_state, projection) do
          persist(
            transaction_state,
            "agent_directory_projection",
            accepted.id,
            accepted,
            sender_id: accepted.principal_id,
            inserted_at: accepted.inserted_at,
            bridge_id: endpoint_id(accepted),
            external_id: accepted.jidoka_agent_ref["id"]
          )
        end
      end)
    end)
  end

  @impl true
  def get_agent_directory_projection(state, projection_id) when is_binary(projection_id),
    do: fetch_record(state, "agent_directory_projection", projection_id)

  @impl true
  def list_agent_directory_projections(state, opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 100) |> bounded_agent_directory_limit()
    endpoint_ids = Keyword.get(opts, :endpoint_ids)

    case endpoint_ids do
      nil ->
        list_records(state, "agent_directory_projection", [limit: limit], order: "id ASC")

      [] ->
        {:ok, []}

      endpoint_ids when is_list(endpoint_ids) and length(endpoint_ids) <= 500 ->
        placeholders =
          2..(length(endpoint_ids) + 1)
          |> Enum.map_join(", ", &"?#{&1}")

        query_records(
          state,
          "kind = ?1 AND bridge_id IN (#{placeholders})",
          ["agent_directory_projection" | endpoint_ids],
          limit: limit,
          order: "id ASC"
        )

      _invalid ->
        {:error, :invalid_agent_directory_endpoint_filter}
    end
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

  # Identity credential operations

  @impl true
  def save_identity_credential(state, %IdentityCredential{} = credential) do
    binding_lock(state, {:identity_credentials}, fn ->
      transaction(state, fn transaction_state ->
        with :ok <- validate_sqlite_identity_revision(transaction_state, credential) do
          persist_identity_credential(transaction_state, credential)
        end
      end)
    end)
  end

  @impl true
  def get_identity_credential(state, credential_id) when is_binary(credential_id),
    do: fetch_record(state, "identity_credential", credential_id)

  @impl true
  def list_identity_credentials(state, subject_principal_id, opts \\ [])
      when is_binary(subject_principal_id) and is_list(opts) do
    status = Keyword.get(opts, :status)
    provider_id = Keyword.get(opts, :provider_id)
    limit = opts |> Keyword.get(:limit, 100) |> bounded_identity_limit()

    with {:ok, credentials} <-
           query_records(
             state,
             "kind = ?1 AND sender_id = ?2",
             ["identity_credential", subject_principal_id],
             order: "inserted_at ASC, id ASC",
             limit: 501
           ) do
      {:ok,
       credentials
       |> Enum.filter(&(is_nil(status) or &1.status == status))
       |> Enum.filter(&(is_nil(provider_id) or &1.provider_id == provider_id))
       |> Enum.take(limit)}
    end
  end

  @impl true
  def rotate_identity_credential(
        state,
        %IdentityCredential{} = revoked,
        %IdentityCredential{} = replacement
      ) do
    result =
      binding_lock(state, {:identity_credentials}, fn ->
        transaction(state, fn transaction_state ->
          with :ok <- validate_sqlite_identity_revision(transaction_state, revoked),
               :ok <- validate_sqlite_identity_replacement(transaction_state, revoked, replacement),
               {:ok, revoked} <- persist_identity_credential(transaction_state, revoked),
               {:ok, replacement} <- persist_identity_credential(transaction_state, replacement) do
            {:ok, {revoked, replacement}}
          end
        end)
      end)

    case result do
      {:ok, {revoked, replacement}} -> {:ok, revoked, replacement}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def consume_identity_assertion(state, credential_id, assertion_key, expires_at)
      when is_binary(credential_id) and is_binary(assertion_key) and is_struct(expires_at, DateTime) do
    result =
      binding_lock(state, {:identity_assertion, credential_id, assertion_key}, fn ->
        transaction(state, fn transaction_state ->
          consume_sqlite_identity_assertion(
            transaction_state,
            credential_id,
            assertion_key,
            expires_at
          )
        end)
      end)

    case result do
      {:ok, %IdentityAssertionUse{}} -> :ok
      {:error, _reason} = error -> error
    end
  end

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

  defp validate_sqlite_agent_directory_revision(state, projection) do
    case get_agent_directory_projection(state, projection.id) do
      {:error, :not_found} when projection.source_revision == 1 ->
        {:ok, projection}

      {:error, :not_found} ->
        {:error, {:invalid_initial_revision, projection.source_revision}}

      {:ok, stored} ->
        cond do
          AgentDirectoryProjection.equivalent?(stored, projection) ->
            {:ok, stored}

          not AgentDirectoryProjection.same_identity?(stored, projection) ->
            {:error, :agent_directory_identity_immutable}

          projection.source_revision == stored.source_revision ->
            {:error, :agent_directory_revision_conflict}

          projection.source_revision < stored.source_revision ->
            {:error, {:stale_revision, stored.source_revision}}

          projection.source_revision != stored.source_revision + 1 ->
            {:error, {:revision_gap, stored.source_revision, projection.source_revision}}

          true ->
            {:ok, AgentDirectoryProjection.preserve_insertion(projection, stored)}
        end
    end
  end

  defp revise_sqlite_messaging_activity(state, stored, incoming) do
    cond do
      incoming.source_revision < stored.source_revision ->
        {:error, {:stale_activity_revision, stored.source_revision}}

      incoming.source_revision == stored.source_revision and
          MessagingActivityEntry.equivalent?(stored, incoming) ->
        {:ok, stored}

      incoming.source_revision == stored.source_revision ->
        {:error, :activity_projection_conflict}

      not MessagingActivityEntry.same_correlation?(stored, incoming) ->
        {:error, :activity_correlation_immutable}

      true ->
        incoming
        |> MessagingActivityEntry.preserve_insertion(stored)
        |> then(&persist_messaging_activity(state, &1))
    end
  end

  defp persist_messaging_activity(state, entry) do
    persist(state, "messaging_activity", entry.id, entry,
      room_id: entry.room_id,
      thread_id: entry.thread_id,
      sender_id: entry.principal_id,
      inserted_at: entry.source_recorded_at,
      channel: entry.kind,
      bridge_id: entry.execution_ref.integration_id,
      external_id: entry.source_event_id
    )
  end

  defp validate_sqlite_identity_revision(state, credential) do
    case get_identity_credential(state, credential.id) do
      {:error, :not_found} when credential.revision == 1 and credential.status == :active ->
        :ok

      {:error, :not_found} when credential.revision != 1 ->
        {:error, {:invalid_initial_revision, credential.revision}}

      {:error, :not_found} ->
        {:error, {:invalid_initial_status, credential.status}}

      {:ok, stored} when stored == credential ->
        :ok

      {:ok, stored} ->
        cond do
          not identity_credential_identity?(stored, credential) ->
            {:error, :identity_credential_identity_immutable}

          stored.status == :revoked ->
            {:error, :identity_credential_revocation_terminal}

          credential.revision != stored.revision + 1 ->
            {:error, {:stale_revision, stored.revision}}

          true ->
            :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp endpoint_id(%AgentDirectoryProjection{endpoint_ref: nil}), do: nil
  defp endpoint_id(%AgentDirectoryProjection{endpoint_ref: endpoint_ref}), do: endpoint_ref.id

  defp bounded_agent_directory_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_agent_directory_limit(_limit), do: 100

  defp validate_sqlite_identity_replacement(state, revoked, replacement) do
    cond do
      revoked.status != :revoked ->
        {:error, :identity_rotation_requires_revocation}

      replacement.status != :active or replacement.revision != 1 ->
        {:error, :invalid_identity_rotation_replacement}

      replacement.rotated_from_credential_id != revoked.id ->
        {:error, :invalid_identity_rotation_lineage}

      not identity_credential_relation?(revoked, replacement) ->
        {:error, :identity_credential_identity_immutable}

      true ->
        case get_identity_credential(state, replacement.id) do
          {:error, :not_found} -> :ok
          {:ok, _credential} -> {:error, :identity_credential_conflict}
          {:error, _reason} = error -> error
        end
    end
  end

  defp validate_sqlite_revision(state, kind, record, identity?) do
    case fetch_record(state, kind, record.id) do
      {:error, :not_found} when record.revision == 1 ->
        :ok

      {:error, :not_found} ->
        {:error, {:invalid_initial_revision, record.revision}}

      {:ok, stored} when stored == record ->
        :ok

      {:ok, stored} ->
        cond do
          not identity?.(stored, record) ->
            {:error, :authorization_identity_immutable}

          stored.status == :revoked and record.status != :revoked ->
            {:error, :authorization_revocation_terminal}

          record.revision == stored.revision + 1 ->
            :ok

          true ->
            {:error, {:stale_revision, stored.revision}}
        end
    end
  end

  defp identity_credential_identity?(left, right) do
    left.id == right.id and
      identity_credential_relation?(left, right) and
      left.provider_id == right.provider_id and
      left.proof_type == right.proof_type and
      left.proof_ref == right.proof_ref and
      left.key_version_ref == right.key_version_ref and
      left.rotated_from_credential_id == right.rotated_from_credential_id and
      left.issued_at == right.issued_at and
      left.not_before == right.not_before and
      left.expires_at == right.expires_at and
      left.inserted_at == right.inserted_at and
      left.metadata == right.metadata
  end

  defp identity_credential_relation?(left, right) do
    left.issuer_principal_id == right.issuer_principal_id and
      left.subject_principal_id == right.subject_principal_id and
      left.purpose == right.purpose and
      left.conditions == right.conditions
  end

  defp persist_identity_credential(state, credential) do
    persist(state, "identity_credential", credential.id, credential,
      room_id: credential.issuer_principal_id,
      sender_id: credential.subject_principal_id,
      inserted_at: credential.inserted_at,
      channel: credential.purpose,
      bridge_id: credential.provider_id,
      external_id: credential.proof_ref
    )
  end

  defp consume_sqlite_identity_assertion(state, credential_id, assertion_key, expires_at) do
    case fetch_record(state, "identity_assertion", assertion_key) do
      {:ok, %IdentityAssertionUse{expires_at: stored_expiry}} ->
        if DateTime.compare(stored_expiry, DateTime.utc_now()) == :gt do
          {:error, :identity_assertion_replayed}
        else
          with :ok <- delete_record(state, "identity_assertion", assertion_key) do
            persist_identity_assertion(state, credential_id, assertion_key, expires_at)
          end
        end

      {:ok, _stored} ->
        {:error, :identity_assertion_replayed}

      {:error, :not_found} ->
        persist_identity_assertion(state, credential_id, assertion_key, expires_at)

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_identity_assertion(state, credential_id, assertion_key, expires_at) do
    assertion_use = IdentityAssertionUse.new(credential_id, assertion_key, expires_at)

    persist(state, "identity_assertion", assertion_key, assertion_use,
      room_id: credential_id,
      inserted_at: assertion_use.inserted_at,
      external_id: assertion_key
    )
  end

  defp bounded_identity_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_identity_limit(_limit), do: 100

  defp validate_sqlite_membership_scope(state, membership) do
    case get_membership_by_scope(state, membership.room_id, membership.principal_id) do
      {:ok, %{id: membership_id}} when membership_id == membership.id -> :ok
      {:ok, %{id: membership_id}} -> {:error, {:membership_scope_conflict, membership_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp do_save_agent_messaging_endpoint(state, endpoint) do
    jidoka_id = endpoint.jidoka_agent_ref["id"]

    with :ok <- validate_stored_endpoint_identity(state, endpoint),
         :ok <- validate_endpoint_principal(state, endpoint),
         :ok <- validate_endpoint_ref(state, endpoint, jidoka_id) do
      persist(state, "agent_endpoint", endpoint.id, endpoint,
        sender_id: endpoint.principal_id,
        inserted_at: endpoint.inserted_at,
        external_id: jidoka_id
      )
    end
  end

  defp validate_stored_endpoint_identity(state, endpoint) do
    case get_agent_messaging_endpoint(state, endpoint.id) do
      {:ok, stored} ->
        if stored.principal_id == endpoint.principal_id and
             stored.jidoka_agent_ref == endpoint.jidoka_agent_ref do
          :ok
        else
          {:error, :agent_endpoint_identity_immutable}
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp validate_endpoint_principal(state, endpoint) do
    case fetch_one(state, "agent_endpoint", [{"sender_id", endpoint.principal_id}]) do
      {:ok, %{id: endpoint_id}} when endpoint_id == endpoint.id -> :ok
      {:ok, %{id: endpoint_id}} -> {:error, {:agent_endpoint_principal_conflict, endpoint_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_endpoint_ref(state, endpoint, jidoka_id) do
    case get_agent_messaging_endpoint_by_ref(state, jidoka_id) do
      {:ok, %{id: endpoint_id}} when endpoint_id == endpoint.id -> :ok
      {:ok, %{id: endpoint_id}} -> {:error, {:jidoka_agent_ref_conflict, endpoint_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp do_save_room_membership(state, membership) do
    with :ok <- validate_stored_membership_identity(state, membership),
         :ok <- validate_membership_scope(state, membership) do
      persist(state, "room_membership", membership.id, membership,
        room_id: membership.room_id,
        sender_id: membership.principal_id,
        inserted_at: membership.inserted_at,
        external_id: membership.endpoint_id
      )
    end
  end

  defp validate_stored_membership_identity(state, membership) do
    case get_room_membership(state, membership.id) do
      {:ok, stored} ->
        if stored.room_id == membership.room_id and
             stored.endpoint_id == membership.endpoint_id and
             stored.principal_id == membership.principal_id do
          :ok
        else
          {:error, :room_membership_identity_immutable}
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp validate_membership_scope(state, membership) do
    case get_room_membership(state, membership.room_id, membership.endpoint_id) do
      {:ok, %{id: membership_id}} when membership_id == membership.id -> :ok
      {:ok, %{id: membership_id}} -> {:error, {:room_membership_conflict, membership_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp validate_sqlite_policy_scope(state, policy, scope_key) do
    case get_invocation_policy_by_scope(state, policy.target_principal_id, scope_key) do
      {:ok, %{id: policy_id}} when policy_id == policy.id -> :ok
      {:ok, %{id: policy_id}} -> {:error, {:invocation_policy_scope_conflict, policy_id}}
      {:error, :not_found} -> :ok
    end
  end

  defp membership_identity?(stored, record) do
    stored.principal_id == record.principal_id and stored.room_id == record.room_id and
      stored.issuer_principal_id == record.issuer_principal_id
  end

  defp grant_identity?(stored, record) do
    stored.principal_id == record.principal_id and
      stored.issuer_principal_id == record.issuer_principal_id
  end

  defp policy_identity?(stored, record) do
    stored.target_principal_id == record.target_principal_id and
      stored.issuer_principal_id == record.issuer_principal_id and stored.scope == record.scope
  end

  defp filter_authorization_record(records, _field, nil), do: records

  defp filter_authorization_record(records, field, value),
    do: Enum.filter(records, &(Map.get(&1, field) == value))

  defp filter_authorization_action(records, nil), do: records
  defp filter_authorization_action(records, action), do: Enum.filter(records, &(action in &1.actions))

  defp take_authorization_records(records, opts) do
    limit = Keyword.get(opts, :limit, 100)
    limit = if is_integer(limit) and limit > 0, do: min(limit, 501), else: 100
    Enum.take(records, limit)
  end

  defp persist_agent_thread_route(state, route) do
    persist(state, "agent_thread_route", route.id, route,
      room_id: route.room_id,
      thread_id: route.thread_id,
      inserted_at: route.inserted_at,
      external_id: route.endpoint_id
    )
  end

  defp maybe_filter_record(records, _field, nil), do: records
  defp maybe_filter_record(records, field, value), do: Enum.filter(records, &(Map.get(&1, field) == value))

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
         {:ok, columns} <- query_all(db, "PRAGMA table_info(#{@table})", []),
         :ok <- migrate_schema(db, columns, instance_id),
         :ok <- ensure_sender_id_column(db),
         :ok <- backfill_message_sender_ids(db),
         :ok <- create_history_index(db) do
      create_activity_index(db)
    end
  end

  defp migrate_schema(db, [], _instance_id) do
    with :ok <- exec(db, create_table_sql()), do: migrate_binding_indexes(db)
  end

  defp migrate_schema(db, columns, instance_id) do
    if Enum.any?(columns, fn [_cid, name | _rest] -> name == "instance_id" end) do
      migrate_binding_indexes(db)
    else
      migrate_legacy_table(db, instance_id)
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
      with :ok <- dedupe_external_bindings(db), do: create_indexes_locked(db)
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
        with :ok <- dedupe_external_bindings(db), do: create_indexes_locked(db)
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
      sender_id TEXT,
      inserted_at TEXT,
      channel TEXT,
      bridge_id TEXT,
      external_id TEXT,
      payload BLOB NOT NULL,
      PRIMARY KEY (instance_id, kind, id)
    );
    """
  end

  defp migrate_binding_indexes(db) do
    result =
      with :ok <- exec(db, "BEGIN IMMEDIATE"),
           :ok <- dedupe_external_bindings(db),
           :ok <- create_indexes_locked(db),
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

  defp dedupe_external_bindings(db) do
    exec(db, """
    DELETE FROM #{@table}
    WHERE kind = 'room_binding'
      AND rowid NOT IN (
        SELECT MIN(rowid)
        FROM #{@table}
        WHERE kind = 'room_binding'
        GROUP BY instance_id, channel, bridge_id, external_id
      );

    DELETE FROM #{@table}
    WHERE kind = 'participant_binding'
      AND rowid NOT IN (
        SELECT MIN(rowid)
        FROM #{@table}
        WHERE kind = 'participant_binding'
        GROUP BY instance_id, channel, bridge_id, external_id
      );
    """)
  end

  defp create_indexes_locked(db) do
    exec(db, """
    CREATE INDEX IF NOT EXISTS #{@table}_room_idx
      ON #{@table} (instance_id, kind, room_id);

    CREATE INDEX IF NOT EXISTS #{@table}_thread_idx
      ON #{@table} (instance_id, kind, thread_id);

    CREATE INDEX IF NOT EXISTS #{@table}_external_idx
      ON #{@table} (instance_id, kind, channel, bridge_id, external_id);

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_room_binding_unique_idx
      ON #{@table} (instance_id, channel, bridge_id, external_id)
      WHERE kind = 'room_binding';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_participant_binding_unique_idx
      ON #{@table} (instance_id, channel, bridge_id, external_id)
      WHERE kind = 'participant_binding';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_jidoka_delegation_transport_unique_idx
      ON #{@table} (instance_id, bridge_id)
      WHERE kind = 'jidoka_delegation_event';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_jidoka_delegation_emission_unique_idx
      ON #{@table} (instance_id, external_id)
      WHERE kind = 'jidoka_delegation_event';
    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_continuity_session_unique_idx
      ON #{@table} (instance_id, bridge_id, external_id)
      WHERE kind = 'thread_continuity_link' AND external_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS #{@table}_identity_subject_idx
      ON #{@table} (instance_id, kind, sender_id, inserted_at, id)
      WHERE kind = 'identity_credential';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_identity_assertion_unique_idx
      ON #{@table} (instance_id, kind, room_id, external_id)
      WHERE kind = 'identity_assertion';
    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_membership_unique_idx
      ON #{@table} (instance_id, room_id, sender_id)
      WHERE kind = 'membership';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_invocation_policy_unique_idx
      ON #{@table} (instance_id, sender_id, external_id)
      WHERE kind = 'invocation_policy';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_agent_endpoint_ref_unique_idx
      ON #{@table} (instance_id, external_id)
      WHERE kind = 'agent_endpoint';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_room_membership_unique_idx
      ON #{@table} (instance_id, room_id, external_id)
      WHERE kind = 'room_membership';

    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_agent_thread_route_unique_idx
      ON #{@table} (instance_id, thread_id)
      WHERE kind = 'agent_thread_route';
    """)
  end

  defp ensure_sender_id_column(db) do
    with {:ok, columns} <- query_all(db, "PRAGMA table_info(#{@table})", []) do
      if Enum.any?(columns, fn [_index, name | _rest] -> name == "sender_id" end) do
        :ok
      else
        exec(db, "ALTER TABLE #{@table} ADD COLUMN sender_id TEXT")
      end
    end
  end

  defp backfill_message_sender_ids(db) do
    with {:ok, rows} <-
           query_all(
             db,
             "SELECT instance_id, id, payload FROM #{@table} WHERE kind = 'message' AND sender_id IS NULL",
             []
           ) do
      Enum.reduce_while(rows, :ok, fn [instance_id, id, payload], :ok ->
        case :erlang.binary_to_term(payload) do
          %Message{sender_id: sender_id} ->
            case run(
                   db,
                   "UPDATE #{@table} SET sender_id = ?1 WHERE instance_id = ?2 AND kind = 'message' AND id = ?3",
                   [sender_id, instance_id, id]
                 ) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end

          _other ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp create_history_index(db) do
    exec(db, """
    CREATE INDEX IF NOT EXISTS #{@table}_participant_history_idx
      ON #{@table} (instance_id, kind, sender_id, inserted_at, id);
    """)
  end

  defp optional_jidoka_delegation_event(state, event_id) do
    case get_jidoka_delegation_event(state, event_id) do
      {:ok, %JidokaDelegationEvent{} = event} -> {:ok, event}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp optional_continuity_link(state, thread_id) do
    case get_thread_continuity_link(state, thread_id) do
      {:ok, %ThreadContinuityLink{} = link} -> {:ok, link}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_delegation_not_cancelled(state, %JidokaDelegationEvent{} = event) do
    if JidokaDelegationEvent.deliverable?(event) do
      case fetch_record(state, "jidoka_delegation_cancellation", event.delegation_ref.id) do
        {:ok, _marker} -> {:error, :jidoka_delegation_cancelled}
        {:error, :not_found} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp ensure_continuity_session_available(_state, _link, :unchanged), do: :ok

  defp ensure_continuity_session_available(state, %ThreadContinuityLink{} = link, _operation) do
    if ThreadContinuityLink.claims_session?(link) do
      reference = link.continuity_ref

      case fetch_one(state, "thread_continuity_link", [
             {"bridge_id", reference.integration_id},
             {"external_id", reference.session_id}
           ]) do
        {:ok, %ThreadContinuityLink{thread_id: thread_id}} when thread_id == link.thread_id ->
          :ok

        {:ok, %ThreadContinuityLink{} = existing} ->
          {:error, {:continuity_session_scope_conflict, existing.thread_id}}

        {:error, :not_found} ->
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  end

  defp ensure_delegation_transport_available(state, %JidokaDelegationEvent{} = event) do
    case fetch_one(state, "jidoka_delegation_event", [{"bridge_id", event.transport_id}]) do
      {:ok, _existing} -> {:error, :jidoka_delegation_transport_conflict}
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ensure_delegation_emission_available(state, %JidokaDelegationEvent{} = event) do
    emission_claim = delegation_emission_claim(event)

    case fetch_one(state, "jidoka_delegation_event", [{"external_id", emission_claim}]) do
      {:ok, _existing} -> {:error, :jidoka_delegation_emission_conflict}
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp persist_jidoka_delegation_event(state, %JidokaDelegationEvent{} = event) do
    persist(state, "jidoka_delegation_event", event.id, event,
      room_id: event.room_id,
      thread_id: event.thread_id,
      sender_id: event.source_principal_id,
      inserted_at: event.observed_at,
      channel: event.action,
      bridge_id: event.transport_id,
      external_id: delegation_emission_claim(event)
    )
  end

  defp delegation_emission_claim(%JidokaDelegationEvent{} = event) do
    JidokaDelegationEvent.emission_claim(event)
  end

  defp maybe_mark_delegation_cancelled(state, %JidokaDelegationEvent{action: :cancelled} = event) do
    marker = %{delegation_id: event.delegation_ref.id, event_id: event.id, room_id: event.room_id}

    with {:ok, ^marker} <-
           persist(
             state,
             "jidoka_delegation_cancellation",
             event.delegation_ref.id,
             marker,
             room_id: event.room_id
           ) do
      :ok
    end
  end

  defp maybe_mark_delegation_cancelled(_state, %JidokaDelegationEvent{}), do: :ok

  defp persist_continuity_link(state, %ThreadContinuityLink{} = link) do
    reference = link.continuity_ref
    external_id = if ThreadContinuityLink.claims_session?(link), do: reference.session_id

    persist(state, "thread_continuity_link", link.id, link,
      room_id: link.room_id,
      thread_id: link.thread_id,
      sender_id: link.principal_id,
      inserted_at: link.inserted_at,
      channel: link.status,
      bridge_id: reference.integration_id,
      external_id: external_id
    )
  end

  defp create_activity_index(db) do
    exec(db, """
    CREATE INDEX IF NOT EXISTS #{@table}_messaging_activity_scope_idx
      ON #{@table} (instance_id, kind, sender_id, room_id, inserted_at, id)
      WHERE kind = 'messaging_activity';
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
        (instance_id, kind, id, room_id, thread_id, sender_id, inserted_at, channel, bridge_id, external_id, payload)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      ON CONFLICT(instance_id, kind, id) DO UPDATE SET
        room_id = excluded.room_id,
        thread_id = excluded.thread_id,
        sender_id = excluded.sender_id,
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
        Keyword.get(opts, :sender_id),
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

  defp binding_lock(state, key, fun) do
    resource = {__MODULE__, Path.expand(state.path), state.instance_id, :binding, key}

    case :global.trans({resource, self()}, fun) do
      :aborted -> {:error, :binding_lock_aborted}
      result -> result
    end
  end

  @impl true
  def transaction(state, fun) do
    case transaction_connection(state) do
      {:ok, transaction_db, close?} ->
        transaction_state = %{state | db: transaction_db}

        try do
          with :ok <- Sqlite3.set_busy_timeout(transaction_db, 5_000),
               :ok <- exec(transaction_db, "BEGIN IMMEDIATE") do
            finish_transaction(transaction_state, fn -> fun.(transaction_state) end)
          end
        after
          if close?, do: Sqlite3.close(transaction_db)
        end

      {:error, _reason} = error ->
        error
    end
  end

  # A second connection to ":memory:" points at a separate database. The
  # binding lock serializes transactions that use this test-only path. A
  # file-backed database uses a dedicated connection so that an unrelated
  # operation cannot be committed or rolled back with the binding operation.
  defp transaction_connection(%{path: ":memory:", db: db}), do: {:ok, db, false}

  defp transaction_connection(state) do
    case Sqlite3.open(state.path) do
      {:ok, db} -> {:ok, db, true}
      {:error, _reason} = error -> error
    end
  end

  defp finish_transaction(state, fun) do
    result = fun.()

    case result do
      {:ok, _value} ->
        case exec(state.db, "COMMIT") do
          :ok -> result
          {:error, _reason} = error -> rollback(state, error)
        end

      {:error, _reason} = error ->
        rollback(state, error)
    end
  rescue
    exception -> rollback(state, {:error, exception})
  catch
    kind, reason -> rollback(state, {:error, {kind, reason}})
  end

  defp rollback(state, result) do
    _ = exec(state.db, "ROLLBACK")
    result
  end

  defp resolve_room_binding_conflict({:error, reason} = error, state, channel, bridge_id, external_id) do
    if unique_constraint_error?(reason) do
      get_room_by_external_binding(state, channel, bridge_id, external_id)
    else
      error
    end
  end

  defp resolve_room_binding_conflict(result, _state, _channel, _bridge_id, _external_id), do: result

  defp unique_constraint_error?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> String.contains?("unique constraint")
  end

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
    |> find_record(&legacy_participant_external_id_matches?(&1, channel, external_id))
  end

  defp find_participant_binding(state, channel, bridge_id, external_id) do
    with {:ok, binding} <- find_participant_binding_record(state, channel, bridge_id, external_id) do
      if binding.status == :revoked do
        {:error, :external_identity_revoked}
      else
        case get_participant(state, binding.participant_id) do
          {:ok, participant} ->
            {:ok, participant}

          {:error, :not_found} ->
            :ok = delete_participant_binding_record(state, channel, bridge_id, external_id)
            {:error, :not_found}
        end
      end
    end
  end

  defp find_participant_binding_record(state, channel, bridge_id, external_id) do
    state
    |> fetch_one("participant_binding", [
      {"channel", normalize_term(channel)},
      {"bridge_id", normalize_term(bridge_id)},
      {"external_id", normalize_term(external_id)}
    ])
    |> normalize_external_identity_binding_result()
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
    binding =
      ExternalIdentityBinding.new(%{
        principal_id: participant_id,
        participant_id: participant_id,
        channel: channel,
        bridge_id: bridge_id,
        external_id: external_id
      })

    case do_save_external_identity_binding(state, binding) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
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
    case find_participant_binding_record(state, channel, bridge_id, external_id) do
      {:ok, binding} -> delete_record(state, "participant_binding", binding.id)
      {:error, :not_found} -> :ok
    end
  end

  defp participant_binding_lock(state, channel, external_id, fun) do
    resource = {
      __MODULE__,
      Path.expand(state.path),
      state.instance_id,
      :participant_binding,
      normalize_term(channel),
      normalize_term(external_id)
    }

    case :global.trans({resource, self()}, fun) do
      :aborted -> {:error, :participant_binding_lock_aborted}
      result -> result
    end
  end

  defp do_save_external_identity_binding(state, %ExternalIdentityBinding{} = binding) do
    with {:ok, participant} <- get_participant(state, binding.participant_id),
         {:ok, principal} <- ensure_principal(state, participant),
         :ok <- validate_identity_binding(binding, participant, principal) do
      case find_participant_binding_record(
             state,
             binding.channel,
             binding.bridge_id,
             binding.external_id
           ) do
        {:ok, existing} ->
          if existing.principal_id == binding.principal_id and
               existing.participant_id == binding.participant_id do
            updated = %{binding | id: existing.id, inserted_at: existing.inserted_at}
            persist_external_identity_binding(state, updated)
          else
            {:error, {:external_identity_conflict, existing.principal_id}}
          end

        {:error, :not_found} ->
          persist_external_identity_binding(state, binding)
      end
    end
  end

  defp persist_external_identity_binding(state, binding) do
    persist(state, "participant_binding", binding.id, binding,
      room_id: binding.participant_id,
      inserted_at: binding.inserted_at,
      channel: binding.channel,
      bridge_id: binding.bridge_id,
      external_id: binding.external_id
    )
  end

  defp normalize_external_identity_binding_result({:ok, binding}),
    do: {:ok, normalize_external_identity_binding(binding)}

  defp normalize_external_identity_binding_result({:error, _reason} = error), do: error

  defp normalize_external_identity_binding(%ExternalIdentityBinding{} = binding), do: binding

  defp normalize_external_identity_binding(binding) when is_map(binding),
    do: ExternalIdentityBinding.from_legacy(binding)

  defp ensure_principal(state, %Participant{} = participant) do
    case get_principal(state, participant.id) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, :not_found} ->
        principal = Principal.from_participant(participant)
        persist(state, "principal", principal.id, principal, room_id: principal.participant_id)
    end
  end

  defp validate_principal_projection(%Principal{} = principal, %Participant{} = participant) do
    if principal.id == participant.id and
         principal.participant_id == participant.id and
         principal.type == participant.type do
      :ok
    else
      {:error, :principal_participant_mismatch}
    end
  end

  defp validate_existing_principal(state, %Participant{} = participant) do
    case get_principal(state, participant.id) do
      {:ok, principal} -> validate_principal_projection(principal, participant)
      {:error, :not_found} -> :ok
    end
  end

  defp validate_identity_binding(binding, participant, principal) do
    if binding.participant_id == participant.id and
         binding.principal_id == principal.id and
         principal.participant_id == participant.id do
      :ok
    else
      {:error, :principal_participant_mismatch}
    end
  end

  defp validate_principal_controller(_state, %Principal{controller_principal_id: nil}), do: :ok

  defp validate_principal_controller(_state, %Principal{id: id, controller_principal_id: id}),
    do: {:error, :principal_cannot_control_itself}

  defp validate_principal_controller(state, %Principal{controller_principal_id: controller_id}) do
    case get_principal(state, controller_id) do
      {:ok, %Principal{status: :active, verification_state: :revoked}} ->
        {:error, :controller_principal_verification_revoked}

      {:ok, %Principal{status: :active}} ->
        :ok

      {:ok, %Principal{status: status}} ->
        {:error, {:controller_principal_inactive, status}}

      {:error, :not_found} ->
        {:error, :controller_principal_not_found}
    end
  end

  defp participant_matches?(participant, state, query) do
    id_matches?(participant.id, query) and
      name_matches?(participant_name(participant), query) and
      participant_external_id_matches?(participant, state, query)
  end

  defp room_matches?(state, room, query) do
    id_matches?(room.id, query) and
      name_matches?(room.name, query) and
      room_external_binding_matches?(state, room.id, query)
  end

  defp participant_external_id_matches?(participant, state, query) do
    channel = query_value(query, :channel)
    bridge_id = query_value(query, :bridge_id)
    external_id = query_value(query, :external_id)

    cond do
      is_nil(channel) and is_nil(bridge_id) and is_nil(external_id) ->
        true

      is_nil(channel) or is_nil(external_id) ->
        false

      not is_nil(bridge_id) ->
        case get_external_identity_binding(state, channel, bridge_id, external_id) do
          {:ok, binding} -> binding.participant_id == participant.id and binding.status == :active
          {:error, _reason} -> false
        end

      true ->
        legacy_participant_external_id_matches?(participant, channel, external_id)
    end
  end

  defp legacy_participant_external_id_matches?(participant, channel, external_id) do
    expected_channel = normalize_term(channel)
    expected_external_id = normalize_term(external_id)

    Enum.any?(participant.external_ids || %{}, fn {key, value} ->
      normalize_term(key) == expected_channel and normalize_term(value) == expected_external_id
    end)
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

  defp fetch_message_payload(state, message_id) do
    with {:ok, rows} <-
           query_all(
             state.db,
             "SELECT payload FROM #{@table} WHERE instance_id = ?1 AND kind = 'message' AND id = ?2 LIMIT 1",
             [state.instance_id, message_id]
           ) do
      case rows do
        [[payload]] -> {:ok, :erlang.binary_to_term(payload), payload}
        [] -> {:error, :not_found}
      end
    end
  end

  defp compare_and_swap_message(state, message_id, participant_id, receipt, old_payload, updated) do
    with {:ok, rows} <-
           query_all(
             state.db,
             """
             UPDATE #{@table}
             SET payload = ?1
             WHERE instance_id = ?2 AND kind = 'message' AND id = ?3 AND payload = ?4
             RETURNING id
             """,
             [
               {:blob, :erlang.term_to_binary(updated)},
               state.instance_id,
               message_id,
               {:blob, old_payload}
             ]
           ) do
      case rows do
        [[_payload]] ->
          {:ok, updated, :updated}

        [] ->
          mark_message_read(state, message_id, participant_id, receipt)
      end
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
