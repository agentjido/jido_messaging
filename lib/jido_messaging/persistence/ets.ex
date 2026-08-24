defmodule Jido.Messaging.Persistence.ETS do
  @moduledoc """
  In-memory ETS adapter for Jido.Messaging.

  Uses anonymous ETS tables for per-instance isolation, enabling
  multiple messaging instances in the same BEAM without conflicts.

  ## Usage

      defmodule MyApp.Messaging do
        use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
      end

  ## State Structure

  The adapter state contains table IDs for:
  - `:rooms` - Room records keyed by room_id
  - `:participants` - Participant records keyed by participant_id
  - `:principals` - Principal records keyed by canonical principal_id
  - `:threads` - Thread records keyed by thread_id
  - `:messages` - Message records keyed by message_id
  - `:room_messages` - Index of message_ids by room_id (bag table)
  - `:thread_messages` - Index of message_ids by thread_id (bag table)
  - `:room_bindings` - External binding to room_id mapping
  - `:participant_bindings` - External ID to participant_id mapping
  - `:messaging_activities` - Safe Jidoka activity projections by activity ID
  - `:principal_activities` - Index of activity IDs by principal ID
  - `:participant_bindings` - Scoped ExternalIdentityBinding records
  - `:agent_endpoints` - Durable Jidoka messaging endpoint records
  - `:room_memberships` - Durable room membership records
  - `:agent_thread_routes` - Durable thread-to-endpoint routes
  - `:onboarding_flows` - Onboarding flow records keyed by onboarding_id
  - `:ingress_subscriptions` - Bridge/provider subscription metadata
  - `:agent_directory_projections` - Safe revisioned Jidoka discovery records
  - `:identity_credentials` - Revisioned controller credential records
  - `:identity_assertions` - Hashed, single-use proof assertion records
  - `:memberships` - Canonical principal room memberships
  - `:principal_grants` - Revisioned messaging grants
  - `:invocation_policies` - Revisioned agent invocation policies
  """

  @behaviour Jido.Messaging.Persistence
  @behaviour Jido.Messaging.Directory

  @schema Zoi.struct(
            __MODULE__,
            %{
              rooms: Zoi.any(),
              participants: Zoi.any(),
              principals: Zoi.any(),
              threads: Zoi.any(),
              room_threads: Zoi.any(),
              thread_external_ids: Zoi.any(),
              thread_roots: Zoi.any(),
              messages: Zoi.any(),
              room_messages: Zoi.any(),
              thread_messages: Zoi.any(),
              room_bindings: Zoi.any(),
              room_bindings_by_room: Zoi.any(),
              room_bindings_by_id: Zoi.any(),
              participant_bindings: Zoi.any(),
              agent_endpoints: Zoi.any(),
              agent_endpoints_by_ref: Zoi.any(),
              room_memberships: Zoi.any(),
              room_memberships_by_scope: Zoi.any(),
              agent_thread_routes: Zoi.any(),
              message_external_ids: Zoi.any(),
              messaging_activities: Zoi.any(),
              principal_activities: Zoi.any(),
              onboarding_flows: Zoi.any(),
              bridge_configs: Zoi.any(),
              ingress_subscriptions: Zoi.any(),
              routing_policies: Zoi.any(),
              jidoka_delegation_events: Zoi.any(),
              jidoka_delegation_cancellations: Zoi.any(),
              thread_continuity_links: Zoi.any(),
              agent_directory_projections: Zoi.any(),
              identity_credentials: Zoi.any(),
              identity_assertions: Zoi.any(),
              memberships: Zoi.any(),
              memberships_by_scope: Zoi.any(),
              principal_grants: Zoi.any(),
              invocation_policies: Zoi.any(),
              invocation_policies_by_scope: Zoi.any()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  alias Jido.Chat.{Participant, Room}

  alias Jido.Messaging.{
    ActivityPage,
    AgentDirectoryProjection,
    AgentMessagingEndpoint,
    AgentThreadRoute,
    AuthorizationScope,
    BridgeConfig,
    ExternalIdentityBinding,
    Grant,
    IdentityAssertionUse,
    IdentityCredential,
    IngressSubscription,
    InvocationPolicy,
    JidokaContinuityRef,
    JidokaDelegationEvent,
    Membership,
    Message,
    MessagingActivityEntry,
    Principal,
    RoomBinding,
    RoomMembership,
    Thread,
    ThreadContinuityLink
  }

  @impl true
  def init(_opts) do
    state =
      struct!(__MODULE__, %{
        rooms: :ets.new(:rooms, [:set, :public]),
        participants: :ets.new(:participants, [:set, :public]),
        principals: :ets.new(:principals, [:set, :public]),
        threads: :ets.new(:threads, [:set, :public]),
        room_threads: :ets.new(:room_threads, [:bag, :public]),
        thread_external_ids: :ets.new(:thread_external_ids, [:set, :public]),
        thread_roots: :ets.new(:thread_roots, [:set, :public]),
        messages: :ets.new(:messages, [:set, :public]),
        room_messages: :ets.new(:room_messages, [:bag, :public]),
        thread_messages: :ets.new(:thread_messages, [:bag, :public]),
        room_bindings: :ets.new(:room_bindings, [:set, :public]),
        room_bindings_by_room: :ets.new(:room_bindings_by_room, [:bag, :public]),
        room_bindings_by_id: :ets.new(:room_bindings_by_id, [:set, :public]),
        participant_bindings: :ets.new(:participant_bindings, [:set, :public]),
        agent_endpoints: :ets.new(:agent_endpoints, [:set, :public]),
        agent_endpoints_by_ref: :ets.new(:agent_endpoints_by_ref, [:set, :public]),
        room_memberships: :ets.new(:room_memberships, [:set, :public]),
        room_memberships_by_scope: :ets.new(:room_memberships_by_scope, [:set, :public]),
        agent_thread_routes: :ets.new(:agent_thread_routes, [:set, :public]),
        message_external_ids: :ets.new(:message_external_ids, [:set, :public]),
        messaging_activities: :ets.new(:messaging_activities, [:set, :public]),
        principal_activities: :ets.new(:principal_activities, [:bag, :public]),
        onboarding_flows: :ets.new(:onboarding_flows, [:set, :public]),
        bridge_configs: :ets.new(:bridge_configs, [:set, :public]),
        ingress_subscriptions: :ets.new(:ingress_subscriptions, [:set, :public]),
        routing_policies: :ets.new(:routing_policies, [:set, :public]),
        jidoka_delegation_events: :ets.new(:jidoka_delegation_events, [:set, :public]),
        jidoka_delegation_cancellations: :ets.new(:jidoka_delegation_cancellations, [:set, :public]),
        thread_continuity_links: :ets.new(:thread_continuity_links, [:set, :public]),
        agent_directory_projections: :ets.new(:agent_directory_projections, [:set, :public]),
        identity_credentials: :ets.new(:identity_credentials, [:set, :public]),
        identity_assertions: :ets.new(:identity_assertions, [:set, :public]),
        memberships: :ets.new(:memberships, [:set, :public]),
        memberships_by_scope: :ets.new(:memberships_by_scope, [:set, :public]),
        principal_grants: :ets.new(:principal_grants, [:set, :public]),
        invocation_policies: :ets.new(:invocation_policies, [:set, :public]),
        invocation_policies_by_scope: :ets.new(:invocation_policies_by_scope, [:set, :public])
      })

    {:ok, state}
  end

  @impl true
  def capabilities(_state), do: [:memory]

  @impl true
  def health_check(_state), do: :ok

  # Room operations

  @impl true
  def save_room(state, %Room{} = room) do
    true = :ets.insert(state.rooms, {room.id, room})
    {:ok, room}
  end

  @impl true
  def get_room(state, room_id) do
    case :ets.lookup(state.rooms, room_id) do
      [{^room_id, room}] -> {:ok, room}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete_room(state, room_id) do
    true = :ets.delete(state.rooms, room_id)
    delete_jidoka_delegation_records(state, room_id)
    delete_continuity_links(state, &(&1.room_id == room_id))

    message_ids = :ets.lookup(state.room_messages, room_id) |> Enum.map(&elem(&1, 1))
    Enum.each(message_ids, &delete_message(state, &1))

    {:ok, bindings} = list_room_bindings(state, room_id)
    Enum.each(bindings, &delete_room_binding(state, &1.id))

    delete_room_agent_records(state, room_id)
    delete_threads_for_room(state, room_id)
    delete_activities_for_room(state, room_id)
    delete_room_authorization_records(state, room_id)
    :ok
  end

  @impl true
  def list_rooms(state, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    rooms =
      :ets.tab2list(state.rooms)
      |> Enum.map(&elem(&1, 1))
      |> Enum.take(limit)

    {:ok, rooms}
  end

  # Participant operations

  @impl true
  def save_participant(state, %Participant{} = participant) do
    with :ok <- validate_existing_principal(state, participant) do
      true = :ets.insert(state.participants, {participant.id, participant})
      {:ok, _principal} = ensure_principal(state, participant)
      {:ok, participant}
    end
  end

  @impl true
  def get_participant(state, participant_id) do
    case :ets.lookup(state.participants, participant_id) do
      [{^participant_id, participant}] -> {:ok, participant}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete_participant(state, participant_id) do
    delete_participant_agent_projections(state, participant_id)
    delete_activities_for_principal(state, participant_id)
    delete_participant_identity_credentials(state, participant_id)
    true = :ets.delete(state.participants, participant_id)
    delete_continuity_links(state, &(&1.principal_id == participant_id))
    delete_principal_authorization_records(state, participant_id)
    true = :ets.delete(state.principals, participant_id)
    delete_participant_bindings(state, participant_id)
    delete_principal_agent_records(state, participant_id)
    :ok
  end

  # Canonical identity operations

  @impl true
  def save_principal(state, %Principal{} = principal) do
    with {:ok, participant} <- get_participant(state, principal.participant_id),
         :ok <- validate_principal_projection(principal, participant),
         :ok <- validate_principal_controller(state, principal) do
      true = :ets.insert(state.principals, {principal.id, principal})
      {:ok, principal}
    end
  end

  @impl true
  def get_principal(state, principal_id) do
    case :ets.lookup(state.principals, principal_id) do
      [{^principal_id, principal}] -> {:ok, principal}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def save_external_identity_binding(state, %ExternalIdentityBinding{} = binding) do
    with {:ok, participant} <- get_participant(state, binding.participant_id),
         {:ok, principal} <- get_principal(state, binding.principal_id),
         :ok <- validate_identity_binding(binding, participant, principal) do
      binding_key = participant_binding_key(binding.channel, binding.bridge_id, binding.external_id)
      save_external_identity_binding_record(state, binding_key, binding)
    end
  end

  @impl true
  def get_external_identity_binding(state, binding_id) do
    state.participant_bindings
    |> :ets.tab2list()
    |> Enum.find_value(fn {_key, stored} ->
      binding = normalize_external_identity_binding(stored)
      if binding.id == binding_id, do: binding
    end)
    |> case do
      nil -> {:error, :not_found}
      binding -> {:ok, binding}
    end
  end

  @impl true
  def get_external_identity_binding(state, channel, bridge_id, external_id) do
    binding_key = participant_binding_key(channel, bridge_id, external_id)

    case :ets.lookup(state.participant_bindings, binding_key) do
      [{^binding_key, stored}] -> {:ok, normalize_external_identity_binding(stored)}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_external_identity_bindings(state, principal_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    bindings =
      state.participant_bindings
      |> :ets.tab2list()
      |> Enum.map(fn {_key, stored} -> normalize_external_identity_binding(stored) end)
      |> Enum.filter(&(&1.principal_id == principal_id))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.take(limit)

    {:ok, bindings}
  end

  # Message operations

  @impl true
  def save_message(state, %Message{} = message) do
    true = :ets.insert(state.messages, {message.id, message})
    true = :ets.insert(state.room_messages, {message.room_id, message.id})
    maybe_index_thread_message(state, message)
    index_external_id(state, message)
    {:ok, message}
  end

  defp index_external_id(_state, %Message{external_id: nil}), do: :ok

  defp index_external_id(state, %Message{} = message) do
    channel = get_in(message.metadata, [:channel])
    bridge_id = get_in(message.metadata, [:bridge_id])

    if channel && bridge_id do
      key = {channel, bridge_id, message.external_id}
      true = :ets.insert(state.message_external_ids, {key, message.id})
    end

    :ok
  end

  @impl true
  def get_message(state, message_id) do
    case :ets.lookup(state.messages, message_id) do
      [{^message_id, message}] -> {:ok, message}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_messages(state, room_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    thread_id = Keyword.get(opts, :thread_id)

    message_ids =
      if is_binary(thread_id) do
        :ets.lookup(state.thread_messages, thread_id)
        |> Enum.map(&elem(&1, 1))
      else
        :ets.lookup(state.room_messages, room_id)
        |> Enum.map(&elem(&1, 1))
      end

    messages =
      message_ids
      |> Enum.flat_map(fn msg_id ->
        case :ets.lookup(state.messages, msg_id) do
          [{^msg_id, msg}] -> [msg]
          [] -> []
        end
      end)
      |> Enum.filter(&(&1.room_id == room_id))
      |> maybe_filter_thread(thread_id)
      |> Enum.sort_by(&message_order_key/1)

    paginate_messages(messages, opts, limit)
  end

  defp paginate_messages(messages, opts, limit) do
    case cursor_direction(opts) do
      :none ->
        {:ok, Enum.take(messages, -limit)}

      {:before, cursor_id} ->
        with {:ok, cursor} <- find_cursor(messages, cursor_id) do
          page = messages |> Enum.filter(&(message_order_key(&1) < message_order_key(cursor))) |> Enum.take(-limit)
          {:ok, page}
        end

      {:after, cursor_id} ->
        with {:ok, cursor} <- find_cursor(messages, cursor_id) do
          page = messages |> Enum.filter(&(message_order_key(&1) > message_order_key(cursor))) |> Enum.take(limit)
          {:ok, page}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cursor_direction(opts) do
    case {Keyword.get(opts, :before), Keyword.get(opts, :after)} do
      {nil, nil} -> :none
      {before, nil} when is_binary(before) and before != "" -> {:before, before}
      {nil, after_cursor} when is_binary(after_cursor) and after_cursor != "" -> {:after, after_cursor}
      {_before, _after_cursor} -> {:error, :invalid_cursor_options}
    end
  end

  defp find_cursor(messages, cursor_id) do
    case Enum.find(messages, &(&1.id == cursor_id)) do
      nil -> {:error, :cursor_not_found}
      cursor -> {:ok, cursor}
    end
  end

  defp message_order_key(message) do
    {message_timestamp_key(message.inserted_at), message.id}
  end

  defp message_timestamp_key(%DateTime{} = inserted_at), do: DateTime.to_iso8601(inserted_at)
  defp message_timestamp_key(nil), do: ""

  @impl true
  def delete_message(state, message_id) do
    case :ets.lookup(state.messages, message_id) do
      [{^message_id, message}] ->
        delete_external_id_index(state, message)
        true = :ets.delete(state.messages, message_id)
        # Remove from room_messages index (bag table - need to delete specific object)
        true = :ets.delete_object(state.room_messages, {message.room_id, message_id})
        maybe_delete_thread_message(state, message)
        :ok

      [] ->
        :ok
    end
  end

  @impl true
  def get_participant_messages(state, participant_id, room_ids, opts \\ [])
      when is_binary(participant_id) and is_list(room_ids) and is_list(opts) do
    allowed_rooms = MapSet.new(room_ids)

    messages =
      state.messages
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1.sender_id == participant_id and MapSet.member?(allowed_rooms, &1.room_id)))

    Jido.Messaging.Transcript.paginate(messages, opts)
  end

  # Messaging activity projection operations

  @impl true
  def save_messaging_activity(state, %MessagingActivityEntry{} = entry) do
    activity_lock(state.messaging_activities, entry.id, fn ->
      case :ets.lookup(state.messaging_activities, entry.id) do
        [] ->
          store_messaging_activity(state, entry)

        [{_id, stored}] ->
          revise_messaging_activity(state, stored, entry)
      end
    end)
  end

  @impl true
  def get_messaging_activity(state, activity_id) when is_binary(activity_id) do
    case :ets.lookup(state.messaging_activities, activity_id) do
      [{^activity_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_principal_activity(state, principal_id, room_ids, opts \\ [])
      when is_binary(principal_id) and is_list(room_ids) and is_list(opts) do
    allowed_rooms = MapSet.new(room_ids)

    entries =
      state.principal_activities
      |> :ets.lookup(principal_id)
      |> Enum.flat_map(fn {^principal_id, activity_id} ->
        case :ets.lookup(state.messaging_activities, activity_id) do
          [{^activity_id, %MessagingActivityEntry{} = entry}] -> [entry]
          [] -> []
        end
      end)
      |> Enum.filter(&MapSet.member?(allowed_rooms, &1.room_id))

    ActivityPage.paginate(entries, opts)
  end

  @impl true
  def mark_message_read(state, message_id, participant_id, receipt) do
    # Global lock IDs are {resource, requester}; the shared resource serializes callers.
    lock_id = {{__MODULE__, state.messages, message_id}, self()}

    :global.trans(lock_id, fn ->
      update_message_receipt(state.messages, message_id, participant_id, receipt)
    end)
  end

  # Thread operations

  @impl true
  def save_thread(state, %Thread{} = thread) do
    remove_thread_indexes(state, thread.id)
    true = :ets.insert(state.threads, {thread.id, thread})
    true = :ets.insert(state.room_threads, {thread.room_id, thread.id})
    maybe_index_thread_external_id(state, thread)
    maybe_index_thread_root(state, thread)
    {:ok, thread}
  end

  @impl true
  def get_thread(state, thread_id) do
    case :ets.lookup(state.threads, thread_id) do
      [{^thread_id, thread}] -> {:ok, thread}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_thread_by_external_id(state, room_id, external_thread_id) do
    key = {room_id, normalize_term(external_thread_id)}

    case :ets.lookup(state.thread_external_ids, key) do
      [{^key, thread_id}] -> get_thread(state, thread_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_thread_by_root_message(state, room_id, root_message_id) do
    key = {room_id, root_message_id}

    case :ets.lookup(state.thread_roots, key) do
      [{^key, thread_id}] -> get_thread(state, thread_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_threads(state, room_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    threads =
      :ets.lookup(state.room_threads, room_id)
      |> Enum.map(&elem(&1, 1))
      |> Enum.flat_map(fn thread_id ->
        case :ets.lookup(state.threads, thread_id) do
          [{^thread_id, thread}] -> [thread]
          [] -> []
        end
      end)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
      |> Enum.take(limit)

    {:ok, threads}
  end

  # Jidoka delegation transport records

  @impl true
  def save_jidoka_delegation_event(state, %JidokaDelegationEvent{} = incoming) do
    lock_id = {{__MODULE__, state.jidoka_delegation_events, :save}, self()}

    :global.trans(lock_id, fn ->
      case lookup_jidoka_delegation_event(state, incoming.id) do
        %JidokaDelegationEvent{} = stored ->
          with :ok <- ensure_delegation_not_cancelled(state, incoming) do
            if JidokaDelegationEvent.equivalent?(stored, incoming) do
              {:ok, stored}
            else
              {:error, :jidoka_delegation_event_conflict}
            end
          end

        nil ->
          with :ok <- ensure_delegation_not_cancelled(state, incoming),
               :ok <- ensure_delegation_transport_available(state, incoming),
               :ok <- ensure_delegation_emission_available(state, incoming) do
            true = :ets.insert(state.jidoka_delegation_events, {incoming.id, incoming})
            maybe_mark_delegation_cancelled(state, incoming)
            {:ok, incoming}
          end
      end
    end)
  end

  # Jidoka continuity correlation

  @impl true
  def save_thread_continuity_link(state, %ThreadContinuityLink{} = incoming) do
    lock_id = {{__MODULE__, state.thread_continuity_links, :save}, self()}

    :global.trans(lock_id, fn ->
      stored = lookup_continuity_link(state, incoming.thread_id)

      with {:ok, accepted, operation} <- ThreadContinuityLink.prepare_save(stored, incoming),
           :ok <- ensure_continuity_session_available(state, accepted, operation) do
        true = :ets.insert(state.thread_continuity_links, {accepted.thread_id, accepted})
        {:ok, accepted}
      end
    end)
  end

  # Principal authorization operations

  @impl true
  def save_membership(state, %Membership{} = membership) do
    scope = {membership.room_id, membership.principal_id}

    authorization_lock(state.memberships, :memberships, fn ->
      with :ok <- validate_revisioned_record(state.memberships, membership, &membership_identity?/2),
           :ok <- validate_scope_index(state.memberships_by_scope, state.memberships, scope, membership.id) do
        true = :ets.insert(state.memberships, {membership.id, membership})
        true = :ets.insert(state.memberships_by_scope, {scope, membership.id})
        {:ok, membership}
      end
    end)
  end

  # Agent messaging endpoint operations

  @impl true
  def save_agent_messaging_endpoint(state, %AgentMessagingEndpoint{} = endpoint) do
    agent_record_lock(state.agent_endpoints, :endpoints, fn ->
      jidoka_id = endpoint.jidoka_agent_ref["id"]

      with :ok <- validate_endpoint_identity(state, endpoint),
           :ok <- validate_endpoint_ref(state, endpoint, jidoka_id) do
        true = :ets.insert(state.agent_endpoints, {endpoint.id, endpoint})
        true = :ets.insert(state.agent_endpoints_by_ref, {jidoka_id, endpoint.id})
        {:ok, endpoint}
      end
    end)
  end

  @impl true
  def get_jidoka_delegation_event(state, event_id) when is_binary(event_id) do
    case lookup_jidoka_delegation_event(state, event_id) do
      nil -> {:error, :not_found}
      %JidokaDelegationEvent{} = event -> {:ok, event}
    end
  end

  @impl true
  def get_thread_continuity_link(state, thread_id) when is_binary(thread_id) do
    case lookup_continuity_link(state, thread_id) do
      nil -> {:error, :not_found}
      %ThreadContinuityLink{} = link -> {:ok, link}
    end
  end

  @impl true
  def get_agent_messaging_endpoint(state, endpoint_id) do
    case :ets.lookup(state.agent_endpoints, endpoint_id) do
      [{^endpoint_id, endpoint}] -> {:ok, endpoint}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_agent_messaging_endpoint_by_ref(state, jidoka_agent_id) do
    case :ets.lookup(state.agent_endpoints_by_ref, jidoka_agent_id) do
      [{^jidoka_agent_id, endpoint_id}] -> get_agent_messaging_endpoint(state, endpoint_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_agent_messaging_endpoints(state, opts \\ []) do
    endpoints =
      state.agent_endpoints
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> maybe_filter_endpoint(:principal_id, Keyword.get(opts, :principal_id))
      |> maybe_filter_endpoint(:status, Keyword.get(opts, :status))
      |> maybe_filter_endpoint(:availability, Keyword.get(opts, :availability))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.take(Keyword.get(opts, :limit, 100))

    {:ok, endpoints}
  end

  @impl true
  def save_room_membership(state, %RoomMembership{} = membership) do
    scope = {membership.room_id, membership.endpoint_id}

    agent_record_lock(state.room_memberships, :memberships, fn ->
      with :ok <- validate_membership_identity(state, membership),
           :ok <- validate_membership_scope(state, membership, scope) do
        true = :ets.insert(state.room_memberships, {membership.id, membership})
        true = :ets.insert(state.room_memberships_by_scope, {scope, membership.id})
        {:ok, membership}
      end
    end)
  end

  @impl true
  def get_membership(state, membership_id) do
    fetch_authorization_record(state.memberships, membership_id)
  end

  @impl true
  def get_membership_by_scope(state, room_id, principal_id) do
    scope = {room_id, principal_id}

    case :ets.lookup(state.memberships_by_scope, scope) do
      [{^scope, membership_id}] -> get_membership(state, membership_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_room_membership(state, membership_id) do
    case :ets.lookup(state.room_memberships, membership_id) do
      [{^membership_id, membership}] -> {:ok, membership}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_memberships(state, room_id, opts \\ []) do
    records =
      state.memberships
      |> authorization_records()
      |> Enum.filter(&(&1.room_id == room_id))
      |> filter_authorization_record(:principal_id, Keyword.get(opts, :principal_id))
      |> filter_authorization_record(:status, Keyword.get(opts, :status))
      |> take_authorization_records(opts)

    {:ok, records}
  end

  @impl true
  def save_principal_grant(state, %Grant{} = grant) do
    authorization_lock(state.principal_grants, grant.id, fn ->
      with :ok <- validate_revisioned_record(state.principal_grants, grant, &grant_identity?/2) do
        true = :ets.insert(state.principal_grants, {grant.id, grant})
        {:ok, grant}
      end
    end)
  end

  @impl true
  def get_room_membership(state, room_id, endpoint_id) do
    scope = {room_id, endpoint_id}

    case :ets.lookup(state.room_memberships_by_scope, scope) do
      [{^scope, membership_id}] -> get_room_membership(state, membership_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_room_memberships(state, room_id, opts \\ []) do
    memberships =
      state.room_memberships
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1.room_id == room_id))
      |> maybe_filter_membership(:endpoint_id, Keyword.get(opts, :endpoint_id))
      |> maybe_filter_membership(:principal_id, Keyword.get(opts, :principal_id))
      |> maybe_filter_membership(:status, Keyword.get(opts, :status))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.take(Keyword.get(opts, :limit, 100))

    {:ok, memberships}
  end

  @impl true
  def save_agent_thread_route(state, %AgentThreadRoute{} = route) do
    agent_record_lock(state.agent_thread_routes, route.thread_id, fn ->
      case :ets.lookup(state.agent_thread_routes, route.thread_id) do
        [] ->
          true = :ets.insert(state.agent_thread_routes, {route.thread_id, route})
          {:ok, route}

        [{_thread_id, %AgentThreadRoute{id: route_id}}] when route_id == route.id ->
          true = :ets.insert(state.agent_thread_routes, {route.thread_id, route})
          {:ok, route}

        [{_thread_id, existing}] ->
          {:error, {:agent_thread_route_conflict, existing.id}}
      end
    end)
  end

  @impl true
  def get_principal_grant(state, grant_id) do
    fetch_authorization_record(state.principal_grants, grant_id)
  end

  @impl true
  def list_principal_grants(state, principal_id, opts \\ []) do
    records =
      state.principal_grants
      |> authorization_records()
      |> Enum.filter(&(&1.principal_id == principal_id))
      |> filter_authorization_record(:status, Keyword.get(opts, :status))
      |> filter_authorization_action(Keyword.get(opts, :action))
      |> take_authorization_records(opts)

    {:ok, records}
  end

  @impl true
  def save_invocation_policy(state, %InvocationPolicy{} = policy) do
    scope = {policy.target_principal_id, AuthorizationScope.key(policy.scope)}

    authorization_lock(state.invocation_policies, :policies, fn ->
      with :ok <- validate_revisioned_record(state.invocation_policies, policy, &policy_identity?/2),
           :ok <-
             validate_scope_index(
               state.invocation_policies_by_scope,
               state.invocation_policies,
               scope,
               policy.id,
               :invocation_policy_scope_conflict
             ) do
        true = :ets.insert(state.invocation_policies, {policy.id, policy})
        true = :ets.insert(state.invocation_policies_by_scope, {scope, policy.id})
        {:ok, policy}
      end
    end)
  end

  @impl true
  def get_invocation_policy(state, policy_id) do
    fetch_authorization_record(state.invocation_policies, policy_id)
  end

  @impl true
  def get_invocation_policy_by_scope(state, target_principal_id, scope_key) do
    scope = {target_principal_id, scope_key}

    case :ets.lookup(state.invocation_policies_by_scope, scope) do
      [{^scope, policy_id}] -> get_invocation_policy(state, policy_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_agent_thread_route(state, thread_id) do
    case :ets.lookup(state.agent_thread_routes, thread_id) do
      [{^thread_id, route}] -> {:ok, route}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_invocation_policies(state, target_principal_id, opts \\ []) do
    records =
      state.invocation_policies
      |> authorization_records()
      |> Enum.filter(&(&1.target_principal_id == target_principal_id))
      |> filter_authorization_record(:status, Keyword.get(opts, :status))
      |> take_authorization_records(opts)

    {:ok, records}
  end

  @impl true
  def list_agent_thread_routes(state, endpoint_id, opts \\ []) do
    routes =
      state.agent_thread_routes
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1.endpoint_id == endpoint_id))
      |> maybe_filter_route(:room_id, Keyword.get(opts, :room_id))
      |> maybe_filter_route(:status, Keyword.get(opts, :status))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.take(Keyword.get(opts, :limit, 100))

    {:ok, routes}
  end

  # External binding operations

  @impl true
  def get_or_create_room_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    binding_key = binding_key(channel, bridge_id, external_id)

    case :ets.lookup(state.room_bindings, binding_key) do
      [{^binding_key, room_id}] ->
        case get_room(state, room_id) do
          {:ok, _room} = ok ->
            ok

          {:error, :not_found} ->
            # Remove stale binding only if it still points at the missing room.
            true = :ets.delete_object(state.room_bindings, {binding_key, room_id})
            get_or_create_room_by_external_binding(state, channel, bridge_id, external_id, attrs)
        end

      [] ->
        room = build_bound_room(channel, bridge_id, external_id, attrs)
        {:ok, room} = save_room(state, room)

        case :ets.insert_new(state.room_bindings, {binding_key, room.id}) do
          true ->
            {:ok, _binding} =
              create_room_binding(state, room.id, channel, bridge_id, external_id, %{})

            {:ok, room}

          false ->
            resolve_room_binding_race(state, binding_key, room.id)
        end
    end
  end

  @impl true
  def get_or_create_participant_by_external_id(state, channel, external_id, attrs) do
    get_or_create_participant_by_external_binding(state, channel, "default", external_id, attrs)
  end

  @impl true
  def get_or_create_participant_by_external_binding(state, channel, bridge_id, external_id, attrs) do
    binding_key = participant_binding_key(channel, bridge_id, external_id)

    case :ets.lookup(state.participant_bindings, binding_key) do
      [{^binding_key, stored}] ->
        binding = normalize_external_identity_binding(stored)

        if binding.status == :revoked do
          {:error, :external_identity_revoked}
        else
          case get_participant(state, binding.participant_id) do
            {:ok, _participant} = ok ->
              ok

            {:error, :not_found} ->
              # Remove stale binding only if it still points at the missing participant.
              true = :ets.delete_object(state.participant_bindings, {binding_key, stored})

              get_or_create_participant_by_external_binding(
                state,
                channel,
                bridge_id,
                external_id,
                attrs
              )
          end
        end

      [] ->
        participant = build_bound_participant(channel, external_id, attrs)
        {:ok, participant} = save_participant(state, participant)
        binding = build_external_identity_binding(participant.id, channel, bridge_id, external_id)

        case :ets.insert_new(state.participant_bindings, {binding_key, binding}) do
          true ->
            {:ok, participant}

          false ->
            resolve_participant_binding_race(state, binding_key, participant.id)
        end
    end
  end

  @impl true
  def bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) do
    with {:ok, participant} <- get_participant(state, participant_id),
         {:ok, _principal} <- ensure_principal(state, participant) do
      binding_key = participant_binding_key(channel, bridge_id, external_id)
      binding = build_external_identity_binding(participant_id, channel, bridge_id, external_id)

      case :ets.insert_new(state.participant_bindings, {binding_key, binding}) do
        true ->
          :ok

        false ->
          case :ets.lookup(state.participant_bindings, binding_key) do
            [{^binding_key, stored}] ->
              existing = normalize_external_identity_binding(stored)

              cond do
                existing.status == :revoked ->
                  {:error, :external_identity_revoked}

                existing.participant_id == participant_id ->
                  :ok

                true ->
                  {:error, {:external_identity_conflict, existing.participant_id}}
              end
          end
      end
    end
  end

  @impl true
  def get_message_by_external_id(state, channel, bridge_id, external_id) do
    key = {channel, bridge_id, external_id}

    case :ets.lookup(state.message_external_ids, key) do
      [{^key, message_id}] -> get_message(state, message_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def update_message_external_id(state, message_id, external_id) do
    case get_message(state, message_id) do
      {:ok, message} ->
        channel = get_in(message.metadata, [:channel])
        bridge_id = get_in(message.metadata, [:bridge_id])

        delete_external_id_index(state, message)
        updated_message = %{message | external_id: external_id}
        true = :ets.insert(state.messages, {message_id, updated_message})

        if channel && bridge_id do
          key = {channel, bridge_id, external_id}
          true = :ets.insert(state.message_external_ids, {key, message_id})
        end

        {:ok, updated_message}

      {:error, :not_found} = error ->
        error
    end
  end

  # Room binding operations

  @impl true
  def get_room_by_external_binding(state, channel, bridge_id, external_id) do
    binding_key = binding_key(channel, bridge_id, external_id)

    case :ets.lookup(state.room_bindings, binding_key) do
      [{^binding_key, room_id}] -> get_room(state, room_id)
      [] -> {:error, :not_found}
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

    key = binding_key(channel, binding.bridge_id, external_id)
    true = :ets.insert(state.room_bindings, {key, room_id})

    true = :ets.insert(state.room_bindings_by_id, {binding.id, binding})
    true = :ets.insert(state.room_bindings_by_room, {room_id, binding.id})

    {:ok, binding}
  end

  @impl true
  def list_room_bindings(state, room_id) do
    binding_ids =
      :ets.lookup(state.room_bindings_by_room, room_id)
      |> Enum.map(&elem(&1, 1))

    bindings =
      binding_ids
      |> Enum.flat_map(fn binding_id ->
        case :ets.lookup(state.room_bindings_by_id, binding_id) do
          [{^binding_id, binding}] -> [binding]
          [] -> []
        end
      end)

    {:ok, bindings}
  end

  @impl true
  def delete_room_binding(state, binding_id) do
    case :ets.lookup(state.room_bindings_by_id, binding_id) do
      [{^binding_id, binding}] ->
        key = binding_key(binding.channel, binding.bridge_id, binding.external_room_id)
        true = :ets.delete_object(state.room_bindings, {key, binding.room_id})
        true = :ets.delete(state.room_bindings_by_id, binding_id)
        true = :ets.delete_object(state.room_bindings_by_room, {binding.room_id, binding_id})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # Directory operations

  @impl Jido.Messaging.Directory
  def lookup(state, target, query) when is_map(query) do
    directory_lookup(state, target, query, [])
  end

  @impl Jido.Messaging.Directory
  def search(state, target, query) when is_map(query) do
    directory_search(state, target, query, [])
  end

  @impl true
  def directory_lookup(state, target, query, opts \\ []) when is_map(query) do
    case directory_search(state, target, query, opts) do
      {:ok, [entry]} ->
        {:ok, entry}

      {:ok, []} ->
        {:error, :not_found}

      {:ok, matches} ->
        {:error, {:ambiguous, matches}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def directory_search(state, :participant, query, _opts) when is_map(query) do
    participants =
      :ets.tab2list(state.participants)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&participant_matches?(&1, state, query))
      |> Enum.sort_by(& &1.id)

    {:ok, participants}
  end

  def directory_search(state, :room, query, _opts) when is_map(query) do
    rooms =
      :ets.tab2list(state.rooms)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&room_matches?(&1, state, query))
      |> Enum.sort_by(& &1.id)

    {:ok, rooms}
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
    lock_id = {{__MODULE__, state.agent_directory_projections, projection.id}, self()}

    case :global.trans(lock_id, fn ->
           case validate_agent_directory_revision(state.agent_directory_projections, projection) do
             {:store, accepted} ->
               true = :ets.insert(state.agent_directory_projections, {accepted.id, accepted})
               {:ok, accepted}

             {:ok, _stored} = result ->
               result

             {:error, _reason} = error ->
               error
           end
         end) do
      :aborted -> {:error, :agent_directory_lock_aborted}
      result -> result
    end
  end

  @impl true
  def get_agent_directory_projection(state, projection_id) when is_binary(projection_id) do
    case :ets.lookup(state.agent_directory_projections, projection_id) do
      [{^projection_id, projection}] -> {:ok, projection}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_agent_directory_projections(state, opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 100) |> bounded_agent_directory_limit()

    with {:ok, endpoint_ids} <-
           opts |> Keyword.get(:endpoint_ids) |> normalize_agent_directory_endpoint_filter() do
      projections =
        state.agent_directory_projections
        |> :ets.tab2list()
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&agent_directory_endpoint_matches?(&1, endpoint_ids))
        |> Enum.sort_by(& &1.id)
        |> Enum.take(limit)

      {:ok, projections}
    end
  end

  # Onboarding operations

  @impl true
  def save_onboarding(state, onboarding_flow) when is_map(onboarding_flow) do
    onboarding_id = Map.get(onboarding_flow, :onboarding_id) || Map.get(onboarding_flow, "onboarding_id")

    if is_binary(onboarding_id) and onboarding_id != "" do
      true = :ets.insert(state.onboarding_flows, {onboarding_id, onboarding_flow})
      {:ok, onboarding_flow}
    else
      {:error, :invalid_onboarding_id}
    end
  end

  @impl true
  def get_onboarding(state, onboarding_id) when is_binary(onboarding_id) do
    case :ets.lookup(state.onboarding_flows, onboarding_id) do
      [{^onboarding_id, onboarding_flow}] -> {:ok, onboarding_flow}
      [] -> {:error, :not_found}
    end
  end

  # Identity credential operations

  @impl true
  def save_identity_credential(state, %IdentityCredential{} = credential) do
    identity_lock(state.identity_credentials, fn ->
      with :ok <- validate_identity_credential_revision(state.identity_credentials, credential) do
        true = :ets.insert(state.identity_credentials, {credential.id, credential})
        {:ok, credential}
      end
    end)
  end

  @impl true
  def get_identity_credential(state, credential_id) when is_binary(credential_id) do
    case :ets.lookup(state.identity_credentials, credential_id) do
      [{^credential_id, credential}] -> {:ok, credential}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_identity_credentials(state, subject_principal_id, opts \\ [])
      when is_binary(subject_principal_id) and is_list(opts) do
    status = Keyword.get(opts, :status)
    provider_id = Keyword.get(opts, :provider_id)
    limit = opts |> Keyword.get(:limit, 100) |> bounded_identity_limit()

    credentials =
      state.identity_credentials
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(&1.subject_principal_id == subject_principal_id))
      |> Enum.filter(&(is_nil(status) or &1.status == status))
      |> Enum.filter(&(is_nil(provider_id) or &1.provider_id == provider_id))
      |> Enum.sort_by(&{DateTime.to_iso8601(&1.inserted_at), &1.id})
      |> Enum.take(limit)

    {:ok, credentials}
  end

  @impl true
  def rotate_identity_credential(
        state,
        %IdentityCredential{} = revoked,
        %IdentityCredential{} = replacement
      ) do
    identity_lock(state.identity_credentials, fn ->
      with :ok <- validate_identity_credential_revision(state.identity_credentials, revoked),
           :ok <- validate_identity_replacement(state.identity_credentials, revoked, replacement) do
        true =
          :ets.insert(state.identity_credentials, [
            {revoked.id, revoked},
            {replacement.id, replacement}
          ])

        {:ok, revoked, replacement}
      end
    end)
  end

  @impl true
  def consume_identity_assertion(state, credential_id, assertion_key, expires_at)
      when is_binary(credential_id) and is_binary(assertion_key) and is_struct(expires_at, DateTime) do
    identity_assertion_lock(state.identity_assertions, credential_id, assertion_key, fn ->
      now = DateTime.utc_now()

      case :ets.lookup(state.identity_assertions, {credential_id, assertion_key}) do
        [{{^credential_id, ^assertion_key}, %IdentityAssertionUse{expires_at: stored_expiry}}] ->
          if DateTime.compare(stored_expiry, now) == :gt do
            {:error, :identity_assertion_replayed}
          else
            store_identity_assertion(state, credential_id, assertion_key, expires_at)
          end

        [_stored] ->
          {:error, :identity_assertion_replayed}

        [] ->
          store_identity_assertion(state, credential_id, assertion_key, expires_at)
      end
    end)
  end

  # Bridge/routing control plane persistence

  @impl true
  def save_bridge_config(state, %BridgeConfig{} = bridge_config) do
    with :ok <- BridgeConfig.validate_for_storage(bridge_config) do
      true = :ets.insert(state.bridge_configs, {bridge_config.id, bridge_config})
      {:ok, bridge_config}
    end
  end

  @impl true
  def get_bridge_config(state, bridge_id) when is_binary(bridge_id) do
    case :ets.lookup(state.bridge_configs, bridge_id) do
      [{^bridge_id, bridge_config}] -> {:ok, bridge_config}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_bridge_configs(state, opts \\ []) do
    enabled_filter = Keyword.get(opts, :enabled)

    configs =
      :ets.tab2list(state.bridge_configs)
      |> Enum.map(&elem(&1, 1))
      |> maybe_filter_enabled(enabled_filter)
      |> Enum.sort_by(& &1.id)

    {:ok, configs}
  end

  @impl true
  def delete_bridge_config(state, bridge_id) when is_binary(bridge_id) do
    case :ets.take(state.bridge_configs, bridge_id) do
      [] -> {:error, :not_found}
      _ -> :ok
    end
  end

  @impl true
  def save_ingress_subscription(state, %IngressSubscription{} = subscription) do
    key = ingress_subscription_key(subscription.bridge_id, subscription.subscription_id)
    true = :ets.insert(state.ingress_subscriptions, {key, subscription})
    {:ok, subscription}
  end

  @impl true
  def list_ingress_subscriptions(state, bridge_id, opts \\ []) when is_binary(bridge_id) and is_list(opts) do
    status_filter = Keyword.get(opts, :status)

    subscriptions =
      state.ingress_subscriptions
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{^bridge_id, _subscription_id}, %IngressSubscription{} = subscription} -> [subscription]
        _other -> []
      end)
      |> maybe_filter_subscription_status(status_filter)
      |> Enum.sort_by(& &1.subscription_id)

    {:ok, subscriptions}
  end

  @impl true
  def delete_ingress_subscription(state, bridge_id, subscription_id)
      when is_binary(bridge_id) and is_binary(subscription_id) do
    case :ets.take(state.ingress_subscriptions, ingress_subscription_key(bridge_id, subscription_id)) do
      [] -> {:error, :not_found}
      _ -> :ok
    end
  end

  @impl true
  def save_routing_policy(state, routing_policy) do
    true = :ets.insert(state.routing_policies, {routing_policy.room_id, routing_policy})
    {:ok, routing_policy}
  end

  @impl true
  def get_routing_policy(state, room_id) when is_binary(room_id) do
    case :ets.lookup(state.routing_policies, room_id) do
      [{^room_id, routing_policy}] -> {:ok, routing_policy}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete_routing_policy(state, room_id) when is_binary(room_id) do
    case :ets.take(state.routing_policies, room_id) do
      [] -> {:error, :not_found}
      _ -> :ok
    end
  end

  defp revise_messaging_activity(state, stored, incoming) do
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
        incoming = MessagingActivityEntry.preserve_insertion(incoming, stored)
        true = :ets.insert(state.messaging_activities, {incoming.id, incoming})
        {:ok, incoming}
    end
  end

  defp store_messaging_activity(state, entry) do
    true = :ets.insert(state.messaging_activities, {entry.id, entry})
    true = :ets.insert(state.principal_activities, {entry.principal_id, entry.id})
    {:ok, entry}
  end

  defp delete_activities_for_room(state, room_id) do
    state.messaging_activities
    |> :ets.tab2list()
    |> Enum.each(fn
      {activity_id, %MessagingActivityEntry{room_id: ^room_id}} ->
        delete_messaging_activity(state, activity_id)

      _entry ->
        :ok
    end)

    :ok
  end

  defp delete_activities_for_principal(state, principal_id) do
    state.principal_activities
    |> :ets.lookup(principal_id)
    |> Enum.each(fn {^principal_id, activity_id} ->
      delete_messaging_activity(state, activity_id)
    end)

    :ok
  end

  defp delete_messaging_activity(state, activity_id) do
    activity_lock(state.messaging_activities, activity_id, fn ->
      case :ets.take(state.messaging_activities, activity_id) do
        [{^activity_id, entry}] ->
          true = :ets.delete_object(state.principal_activities, {entry.principal_id, activity_id})
          :ok

        [] ->
          :ok
      end
    end)
  end

  defp activity_lock(table, activity_id, fun) do
    case :global.trans({{__MODULE__, table, activity_id}, self()}, fun) do
      :aborted -> {:error, :activity_projection_lock_aborted}
      result -> result
    end
  end

  defp validate_identity_credential_revision(table, credential) do
    case :ets.lookup(table, credential.id) do
      [] when credential.revision == 1 and credential.status == :active ->
        :ok

      [] when credential.revision != 1 ->
        {:error, {:invalid_initial_revision, credential.revision}}

      [] ->
        {:error, {:invalid_initial_status, credential.status}}

      [{_id, stored}] when stored == credential ->
        :ok

      [{_id, stored}] ->
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
    end
  end

  defp validate_identity_replacement(table, revoked, replacement) do
    cond do
      revoked.status != :revoked ->
        {:error, :identity_rotation_requires_revocation}

      replacement.status != :active or replacement.revision != 1 ->
        {:error, :invalid_identity_rotation_replacement}

      replacement.rotated_from_credential_id != revoked.id ->
        {:error, :invalid_identity_rotation_lineage}

      not identity_credential_relation?(revoked, replacement) ->
        {:error, :identity_credential_identity_immutable}

      :ets.member(table, replacement.id) ->
        {:error, :identity_credential_conflict}

      true ->
        :ok
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

  defp store_identity_assertion(state, credential_id, assertion_key, expires_at) do
    use = IdentityAssertionUse.new(credential_id, assertion_key, expires_at)
    true = :ets.insert(state.identity_assertions, {{credential_id, assertion_key}, use})
    :ok
  end

  defp delete_participant_identity_credentials(state, participant_id) do
    identity_lock(state.identity_credentials, fn ->
      credential_ids =
        state.identity_credentials
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {credential_id, %IdentityCredential{} = credential}
          when credential.issuer_principal_id == participant_id or
                 credential.subject_principal_id == participant_id ->
            [credential_id]

          _record ->
            []
        end)

      Enum.each(credential_ids, fn credential_id ->
        true = :ets.delete(state.identity_credentials, credential_id)
        :ets.match_delete(state.identity_assertions, {{credential_id, :_}, :_})
      end)

      :ok
    end)
  end

  defp bounded_identity_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_identity_limit(_limit), do: 100

  defp identity_lock(table, fun) do
    case :global.trans({{__MODULE__, table, :identity_credentials}, self()}, fun) do
      :aborted -> {:error, :identity_credential_lock_aborted}
      result -> result
    end
  end

  defp identity_assertion_lock(table, credential_id, assertion_key, fun) do
    lock = {{__MODULE__, table, credential_id, assertion_key}, self()}

    case :global.trans(lock, fun) do
      :aborted -> {:error, :identity_assertion_lock_aborted}
      result -> result
    end
  end

  defp participant_matches?(participant, state, query) do
    id_matches?(participant.id, query) and
      name_matches?(participant_name(participant), query) and
      participant_external_id_matches?(participant, state, query)
  end

  defp maybe_filter_enabled(configs, nil), do: configs
  defp maybe_filter_enabled(configs, value), do: Enum.filter(configs, &(&1.enabled == value))

  defp maybe_filter_subscription_status(subscriptions, nil), do: subscriptions

  defp maybe_filter_subscription_status(subscriptions, value) do
    Enum.filter(subscriptions, &(&1.status == value))
  end

  defp room_matches?(room, state, query) do
    id_matches?(room.id, query) and
      name_matches?(room.name, query) and
      room_external_binding_matches?(room.id, state, query)
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
        expected_channel = normalize_term(channel)
        expected_external_id = normalize_term(external_id)

        Enum.any?(participant.external_ids, fn {key, value} ->
          normalize_term(key) == expected_channel and normalize_term(value) == expected_external_id
        end)
    end
  end

  defp room_external_binding_matches?(room_id, state, query) do
    channel = query_value(query, :channel)
    bridge_id = query_value(query, :bridge_id)
    external_id = query_value(query, :external_id)

    cond do
      is_nil(channel) and is_nil(bridge_id) and is_nil(external_id) ->
        true

      is_nil(channel) or is_nil(bridge_id) or is_nil(external_id) ->
        false

      true ->
        expected_channel = normalize_term(channel)
        expected_bridge_id = normalize_term(bridge_id)
        expected_external_id = normalize_term(external_id)

        :ets.tab2list(state.room_bindings)
        |> Enum.any?(fn {{binding_channel, binding_bridge_id, binding_external_id}, binding_room_id} ->
          binding_room_id == room_id and
            normalize_term(binding_channel) == expected_channel and
            normalize_term(binding_bridge_id) == expected_bridge_id and
            normalize_term(binding_external_id) == expected_external_id
        end)
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
    get_in(participant.identity, [:name]) || get_in(participant.identity, ["name"])
  end

  defp query_value(query, key) do
    Map.get(query, key) || Map.get(query, Atom.to_string(key))
  end

  defp binding_key(channel, bridge_id, external_id) do
    {channel, normalize_term(bridge_id), normalize_term(external_id)}
  end

  defp ingress_subscription_key(bridge_id, subscription_id) do
    {to_string(bridge_id), to_string(subscription_id)}
  end

  defp maybe_index_thread_message(_state, %Message{thread_id: nil}), do: :ok

  defp maybe_index_thread_message(state, %Message{thread_id: thread_id, id: message_id})
       when is_binary(thread_id) do
    true = :ets.insert(state.thread_messages, {thread_id, message_id})
    :ok
  end

  defp update_message_receipt(table, message_id, participant_id, receipt) do
    case :ets.lookup(table, message_id) do
      [{^message_id, message}] ->
        case Jido.Messaging.ReadReceipt.apply_to_message(message, participant_id, receipt) do
          {updated, :updated} ->
            true = :ets.insert(table, {message_id, updated})
            {:ok, updated, :updated}

          {unchanged, :unchanged} ->
            {:ok, unchanged, :unchanged}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp maybe_delete_thread_message(_state, %Message{thread_id: nil}), do: :ok

  defp maybe_delete_thread_message(state, %Message{thread_id: thread_id, id: message_id})
       when is_binary(thread_id) do
    true = :ets.delete_object(state.thread_messages, {thread_id, message_id})
    :ok
  end

  defp delete_external_id_index(_state, %Message{external_id: nil}), do: :ok

  defp delete_external_id_index(state, %Message{} = message) do
    channel = get_in(message.metadata, [:channel])
    bridge_id = get_in(message.metadata, [:bridge_id])

    if channel && bridge_id do
      key = {channel, bridge_id, message.external_id}
      true = :ets.delete_object(state.message_external_ids, {key, message.id})
    end

    :ok
  end

  defp maybe_filter_thread(messages, nil), do: messages
  defp maybe_filter_thread(messages, thread_id), do: Enum.filter(messages, &(&1.thread_id == thread_id))

  defp maybe_index_thread_external_id(_state, %Thread{external_thread_id: nil}), do: :ok

  defp maybe_index_thread_external_id(
         state,
         %Thread{room_id: room_id, external_thread_id: external_thread_id, id: thread_id}
       ) do
    true =
      :ets.insert(
        state.thread_external_ids,
        {{room_id, normalize_term(external_thread_id)}, thread_id}
      )

    :ok
  end

  defp maybe_index_thread_root(_state, %Thread{root_message_id: nil}), do: :ok

  defp maybe_index_thread_root(
         state,
         %Thread{room_id: room_id, root_message_id: root_message_id, id: thread_id}
       ) do
    true = :ets.insert(state.thread_roots, {{room_id, root_message_id}, thread_id})
    :ok
  end

  defp remove_thread_indexes(state, thread_id) do
    case :ets.lookup(state.threads, thread_id) do
      [{^thread_id, existing_thread}] ->
        true = :ets.delete_object(state.room_threads, {existing_thread.room_id, thread_id})

        if is_binary(existing_thread.external_thread_id) do
          true =
            :ets.delete_object(
              state.thread_external_ids,
              {{existing_thread.room_id, normalize_term(existing_thread.external_thread_id)}, thread_id}
            )
        end

        if is_binary(existing_thread.root_message_id) do
          true =
            :ets.delete_object(
              state.thread_roots,
              {{existing_thread.room_id, existing_thread.root_message_id}, thread_id}
            )
        end

      [] ->
        :ok
    end
  end

  defp delete_threads_for_room(state, room_id) do
    :ets.lookup(state.room_threads, room_id)
    |> Enum.map(&elem(&1, 1))
    |> Enum.each(fn thread_id ->
      remove_thread_indexes(state, thread_id)
      true = :ets.delete(state.threads, thread_id)
      true = :ets.delete(state.thread_messages, thread_id)
    end)

    true = :ets.delete(state.room_threads, room_id)
    :ok
  end

  defp lookup_jidoka_delegation_event(state, event_id) do
    case :ets.lookup(state.jidoka_delegation_events, event_id) do
      [{^event_id, %JidokaDelegationEvent{} = event}] -> event
      [] -> nil
    end
  end

  defp lookup_continuity_link(state, thread_id) do
    case :ets.lookup(state.thread_continuity_links, thread_id) do
      [{^thread_id, %ThreadContinuityLink{} = link}] -> link
      [] -> nil
    end
  end

  defp ensure_delegation_not_cancelled(state, %JidokaDelegationEvent{} = event) do
    if JidokaDelegationEvent.deliverable?(event) and
         :ets.member(state.jidoka_delegation_cancellations, event.delegation_ref.id) do
      {:error, :jidoka_delegation_cancelled}
    else
      :ok
    end
  end

  defp ensure_continuity_session_available(_state, _link, :unchanged), do: :ok

  defp ensure_continuity_session_available(state, %ThreadContinuityLink{} = link, _operation) do
    if ThreadContinuityLink.claims_session?(link) do
      session_key = JidokaContinuityRef.session_key(link.continuity_ref)

      state.thread_continuity_links
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.find(fn existing ->
        existing.thread_id != link.thread_id and
          ThreadContinuityLink.claims_session?(existing) and
          JidokaContinuityRef.session_key(existing.continuity_ref) == session_key
      end)
      |> case do
        nil -> :ok
        existing -> {:error, {:continuity_session_scope_conflict, existing.thread_id}}
      end
    else
      :ok
    end
  end

  defp ensure_delegation_transport_available(state, %JidokaDelegationEvent{} = event) do
    state.jidoka_delegation_events
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.find(&(&1.transport_id == event.transport_id))
    |> case do
      nil -> :ok
      _existing -> {:error, :jidoka_delegation_transport_conflict}
    end
  end

  defp ensure_delegation_emission_available(state, %JidokaDelegationEvent{} = event) do
    claim = JidokaDelegationEvent.emission_claim(event)

    state.jidoka_delegation_events
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.find(&(JidokaDelegationEvent.emission_claim(&1) == claim))
    |> case do
      nil -> :ok
      _existing -> {:error, :jidoka_delegation_emission_conflict}
    end
  end

  defp maybe_mark_delegation_cancelled(state, %JidokaDelegationEvent{action: :cancelled} = event) do
    true =
      :ets.insert(
        state.jidoka_delegation_cancellations,
        {event.delegation_ref.id, event.room_id, event.id}
      )

    :ok
  end

  defp maybe_mark_delegation_cancelled(_state, %JidokaDelegationEvent{}), do: :ok

  defp delete_continuity_links(state, predicate) do
    state.thread_continuity_links
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(predicate)
    |> Enum.each(&:ets.delete(state.thread_continuity_links, &1.thread_id))

    :ok
  end

  defp delete_jidoka_delegation_records(state, room_id) do
    state.jidoka_delegation_events
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.room_id == room_id))
    |> Enum.each(&:ets.delete(state.jidoka_delegation_events, &1.id))

    state.jidoka_delegation_cancellations
    |> :ets.tab2list()
    |> Enum.filter(fn {_delegation_id, marker_room_id, _event_id} -> marker_room_id == room_id end)
    |> Enum.each(fn {delegation_id, _marker_room_id, _event_id} ->
      :ets.delete(state.jidoka_delegation_cancellations, delegation_id)
    end)

    :ok
  end

  defp validate_agent_directory_revision(table, projection) do
    case :ets.lookup(table, projection.id) do
      [] when projection.source_revision == 1 ->
        {:store, projection}

      [] ->
        {:error, {:invalid_initial_revision, projection.source_revision}}

      [{_id, stored}] ->
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
            {:store, AgentDirectoryProjection.preserve_insertion(projection, stored)}
        end
    end
  end

  defp delete_participant_agent_projections(state, participant_id) do
    state.agent_directory_projections
    |> :ets.tab2list()
    |> Enum.each(fn
      {projection_id, %AgentDirectoryProjection{principal_id: ^participant_id}} ->
        true = :ets.delete(state.agent_directory_projections, projection_id)

      _record ->
        :ok
    end)
  end

  defp bounded_agent_directory_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_agent_directory_limit(_limit), do: 100

  defp normalize_agent_directory_endpoint_filter(nil), do: {:ok, nil}

  defp normalize_agent_directory_endpoint_filter(endpoint_ids)
       when is_list(endpoint_ids) and length(endpoint_ids) <= 500,
       do: {:ok, MapSet.new(endpoint_ids)}

  defp normalize_agent_directory_endpoint_filter(_endpoint_ids),
    do: {:error, :invalid_agent_directory_endpoint_filter}

  defp agent_directory_endpoint_matches?(_projection, nil), do: true

  defp agent_directory_endpoint_matches?(%AgentDirectoryProjection{endpoint_ref: nil}, _endpoint_ids), do: false

  defp agent_directory_endpoint_matches?(projection, endpoint_ids) do
    MapSet.member?(endpoint_ids, projection.endpoint_ref.id)
  end

  defp normalize_term(value) when is_binary(value), do: value
  defp normalize_term(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_term(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_term(value), do: inspect(value)

  defp participant_binding_key(channel, bridge_id, external_id) do
    {normalize_term(channel), normalize_term(bridge_id), normalize_term(external_id)}
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

  defp resolve_room_binding_race(state, binding_key, candidate_room_id) do
    case :ets.lookup(state.room_bindings, binding_key) do
      [{^binding_key, room_id}] when room_id == candidate_room_id ->
        get_room(state, room_id)

      [{^binding_key, room_id}] ->
        :ok = delete_room(state, candidate_room_id)
        get_room(state, room_id)

      [] ->
        true = :ets.insert(state.room_bindings, {binding_key, candidate_room_id})
        get_room(state, candidate_room_id)
    end
  end

  defp resolve_participant_binding_race(state, binding_key, candidate_participant_id) do
    case :ets.lookup(state.participant_bindings, binding_key) do
      [{^binding_key, stored}] ->
        binding = normalize_external_identity_binding(stored)

        cond do
          binding.status == :revoked ->
            :ok = delete_participant(state, candidate_participant_id)
            {:error, :external_identity_revoked}

          binding.participant_id == candidate_participant_id ->
            get_participant(state, binding.participant_id)

          true ->
            :ok = delete_participant(state, candidate_participant_id)
            get_participant(state, binding.participant_id)
        end

      [] ->
        {channel, bridge_id, external_id} = binding_key

        binding =
          build_external_identity_binding(
            candidate_participant_id,
            channel,
            bridge_id,
            external_id
          )

        true = :ets.insert(state.participant_bindings, {binding_key, binding})
        get_participant(state, candidate_participant_id)
    end
  end

  defp validate_revisioned_record(table, record, identity?) do
    case :ets.lookup(table, record.id) do
      [] when record.revision == 1 ->
        :ok

      [] ->
        {:error, {:invalid_initial_revision, record.revision}}

      [{_id, stored}] when stored == record ->
        :ok

      [{_id, stored}] ->
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

  defp validate_endpoint_identity(state, endpoint) do
    with :ok <- validate_stored_endpoint_identity(state, endpoint) do
      state.agent_endpoints
      |> :ets.tab2list()
      |> Enum.find(fn {endpoint_id, stored} ->
        endpoint_id != endpoint.id and stored.principal_id == endpoint.principal_id
      end)
      |> case do
        nil -> :ok
        {existing_id, _stored} -> {:error, {:agent_endpoint_principal_conflict, existing_id}}
      end
    end
  end

  defp validate_stored_endpoint_identity(state, endpoint) do
    case :ets.lookup(state.agent_endpoints, endpoint.id) do
      [] ->
        :ok

      [{_endpoint_id, stored}] ->
        if stored.principal_id == endpoint.principal_id and
             stored.jidoka_agent_ref == endpoint.jidoka_agent_ref do
          :ok
        else
          {:error, :agent_endpoint_identity_immutable}
        end
    end
  end

  defp validate_scope_index(index, records, scope, record_id, conflict \\ :membership_scope_conflict) do
    case :ets.lookup(index, scope) do
      [] ->
        :ok

      [{^scope, ^record_id}] ->
        :ok

      [{^scope, existing_id}] ->
        case :ets.lookup(records, existing_id) do
          [{^existing_id, _record}] ->
            {:error, {conflict, existing_id}}

          [] ->
            true = :ets.delete(index, scope)
            :ok
        end
    end
  end

  defp ensure_principal(state, %Participant{} = participant) do
    case get_principal(state, participant.id) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, :not_found} ->
        principal = Principal.from_participant(participant)

        case :ets.insert_new(state.principals, {principal.id, principal}) do
          true -> {:ok, principal}
          false -> get_principal(state, principal.id)
        end
    end
  end

  defp build_external_identity_binding(participant_id, channel, bridge_id, external_id) do
    ExternalIdentityBinding.new(%{
      principal_id: participant_id,
      participant_id: participant_id,
      channel: channel,
      bridge_id: bridge_id,
      external_id: external_id
    })
  end

  defp save_external_identity_binding_record(state, binding_key, binding) do
    case :ets.lookup(state.participant_bindings, binding_key) do
      [] ->
        case :ets.insert_new(state.participant_bindings, {binding_key, binding}) do
          true -> {:ok, binding}
          false -> save_external_identity_binding_record(state, binding_key, binding)
        end

      [{^binding_key, stored}] ->
        existing = normalize_external_identity_binding(stored)

        if existing.principal_id == binding.principal_id and
             existing.participant_id == binding.participant_id do
          updated = %{binding | id: existing.id, inserted_at: existing.inserted_at}
          true = :ets.insert(state.participant_bindings, {binding_key, updated})
          {:ok, updated}
        else
          {:error, {:external_identity_conflict, existing.principal_id}}
        end
    end
  end

  defp validate_endpoint_ref(state, endpoint, jidoka_id) do
    case :ets.lookup(state.agent_endpoints_by_ref, jidoka_id) do
      [] ->
        :ok

      [{^jidoka_id, endpoint_id}] when endpoint_id == endpoint.id ->
        :ok

      [{^jidoka_id, endpoint_id}] ->
        case get_agent_messaging_endpoint(state, endpoint_id) do
          {:ok, _existing} ->
            {:error, {:jidoka_agent_ref_conflict, endpoint_id}}

          {:error, :not_found} ->
            true = :ets.delete(state.agent_endpoints_by_ref, jidoka_id)
            :ok
        end
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

  defp fetch_authorization_record(table, record_id) do
    case :ets.lookup(table, record_id) do
      [{^record_id, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  defp authorization_records(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
  end

  defp filter_authorization_record(records, _field, nil), do: records

  defp filter_authorization_record(records, field, value),
    do: Enum.filter(records, &(Map.get(&1, field) == value))

  defp filter_authorization_action(records, nil), do: records
  defp filter_authorization_action(records, action), do: Enum.filter(records, &(action in &1.actions))

  defp take_authorization_records(records, opts) do
    limit = Keyword.get(opts, :limit, 100)
    limit = if is_integer(limit) and limit > 0, do: min(limit, 501), else: 100

    records
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
    |> Enum.take(limit)
  end

  defp authorization_lock(table, key, fun) do
    case :global.trans({{__MODULE__, table, key}, self()}, fun) do
      :aborted -> {:error, :authorization_lock_aborted}
      result -> result
    end
  end

  defp delete_room_authorization_records(state, room_id) do
    state.memberships
    |> authorization_records()
    |> Enum.each(fn membership ->
      if membership.room_id == room_id,
        do: delete_authorization_membership_record(state, membership)
    end)

    state.principal_grants
    |> authorization_records()
    |> Enum.each(fn grant ->
      if grant.scope.room_id == room_id, do: :ets.delete(state.principal_grants, grant.id)
    end)

    state.invocation_policies
    |> authorization_records()
    |> Enum.each(fn policy ->
      if policy.scope.room_id == room_id, do: delete_policy_record(state, policy)
    end)

    :ok
  end

  defp validate_membership_identity(state, membership) do
    case :ets.lookup(state.room_memberships, membership.id) do
      [] ->
        :ok

      [{_membership_id, stored}] ->
        if stored.room_id == membership.room_id and
             stored.endpoint_id == membership.endpoint_id and
             stored.principal_id == membership.principal_id do
          :ok
        else
          {:error, :room_membership_identity_immutable}
        end
    end
  end

  defp validate_membership_scope(state, membership, scope) do
    case :ets.lookup(state.room_memberships_by_scope, scope) do
      [] ->
        :ok

      [{^scope, membership_id}] when membership_id == membership.id ->
        :ok

      [{^scope, membership_id}] ->
        case get_room_membership(state, membership_id) do
          {:ok, _existing} ->
            {:error, {:room_membership_conflict, membership_id}}

          {:error, :not_found} ->
            true = :ets.delete(state.room_memberships_by_scope, scope)
            :ok
        end
    end
  end

  defp maybe_filter_endpoint(endpoints, _field, nil), do: endpoints
  defp maybe_filter_endpoint(endpoints, field, value), do: Enum.filter(endpoints, &(Map.get(&1, field) == value))

  defp maybe_filter_membership(memberships, _field, nil), do: memberships

  defp maybe_filter_membership(memberships, field, value),
    do: Enum.filter(memberships, &(Map.get(&1, field) == value))

  defp maybe_filter_route(routes, _field, nil), do: routes
  defp maybe_filter_route(routes, field, value), do: Enum.filter(routes, &(Map.get(&1, field) == value))

  defp delete_room_agent_records(state, room_id) do
    state.room_memberships
    |> :ets.tab2list()
    |> Enum.each(fn {_id, membership} ->
      if membership.room_id == room_id, do: delete_membership_record(state, membership)
    end)

    state.agent_thread_routes
    |> :ets.tab2list()
    |> Enum.each(fn {thread_id, route} ->
      if route.room_id == room_id, do: :ets.delete(state.agent_thread_routes, thread_id)
    end)

    :ok
  end

  defp delete_principal_authorization_records(state, principal_id) do
    state.memberships
    |> authorization_records()
    |> Enum.each(fn membership ->
      if membership.principal_id == principal_id,
        do: delete_authorization_membership_record(state, membership)
    end)

    state.principal_grants
    |> authorization_records()
    |> Enum.each(fn grant ->
      if grant.principal_id == principal_id, do: :ets.delete(state.principal_grants, grant.id)
    end)

    state.invocation_policies
    |> authorization_records()
    |> Enum.each(fn policy ->
      if policy.target_principal_id == principal_id, do: delete_policy_record(state, policy)
    end)

    :ok
  end

  defp delete_principal_agent_records(state, principal_id) do
    endpoint_ids =
      state.agent_endpoints
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, endpoint} -> endpoint.principal_id == principal_id end)
      |> Enum.map(fn {id, endpoint} ->
        true = :ets.delete(state.agent_endpoints, id)
        true = :ets.delete(state.agent_endpoints_by_ref, endpoint.jidoka_agent_ref["id"])
        id
      end)

    state.room_memberships
    |> :ets.tab2list()
    |> Enum.each(fn {_id, membership} ->
      if membership.principal_id == principal_id or membership.endpoint_id in endpoint_ids do
        delete_membership_record(state, membership)
      end
    end)

    state.agent_thread_routes
    |> :ets.tab2list()
    |> Enum.each(fn {thread_id, route} ->
      if route.endpoint_id in endpoint_ids, do: :ets.delete(state.agent_thread_routes, thread_id)
    end)

    :ok
  end

  defp delete_authorization_membership_record(state, membership) do
    true = :ets.delete(state.memberships, membership.id)
    true = :ets.delete(state.memberships_by_scope, {membership.room_id, membership.principal_id})
    :ok
  end

  defp delete_policy_record(state, policy) do
    scope = {policy.target_principal_id, AuthorizationScope.key(policy.scope)}
    true = :ets.delete(state.invocation_policies, policy.id)
    true = :ets.delete(state.invocation_policies_by_scope, scope)
    :ok
  end

  defp delete_membership_record(state, membership) do
    true = :ets.delete(state.room_memberships, membership.id)
    true = :ets.delete(state.room_memberships_by_scope, {membership.room_id, membership.endpoint_id})
    :ok
  end

  defp agent_record_lock(table, key, fun) do
    case :global.trans({{__MODULE__, table, key}, self()}, fun) do
      :aborted -> {:error, :agent_record_lock_aborted}
      result -> result
    end
  end

  defp normalize_external_identity_binding(%ExternalIdentityBinding{} = binding), do: binding

  defp normalize_external_identity_binding(binding) when is_map(binding),
    do: ExternalIdentityBinding.from_legacy(binding)

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

  defp delete_participant_bindings(state, participant_id) do
    state.participant_bindings
    |> :ets.tab2list()
    |> Enum.each(fn {_key, stored} = record ->
      if normalize_external_identity_binding(stored).participant_id == participant_id do
        true = :ets.delete_object(state.participant_bindings, record)
      end
    end)
  end
end
