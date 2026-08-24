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
  - `:threads` - Thread records keyed by thread_id
  - `:messages` - Message records keyed by message_id
  - `:room_messages` - Index of message_ids by room_id (bag table)
  - `:thread_messages` - Index of message_ids by thread_id (bag table)
  - `:room_bindings` - External binding to room_id mapping
  - `:participant_bindings` - External ID to participant_id mapping
  - `:onboarding_flows` - Onboarding flow records keyed by onboarding_id
  - `:ingress_subscriptions` - Bridge/provider subscription metadata
  """

  @behaviour Jido.Messaging.Persistence
  @behaviour Jido.Messaging.Directory

  @schema Zoi.struct(
            __MODULE__,
            %{
              rooms: Zoi.any(),
              participants: Zoi.any(),
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
              message_external_ids: Zoi.any(),
              onboarding_flows: Zoi.any(),
              bridge_configs: Zoi.any(),
              ingress_subscriptions: Zoi.any(),
              routing_policies: Zoi.any(),
              jidoka_delegation_events: Zoi.any(),
              jidoka_delegation_cancellations: Zoi.any()
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
    BridgeConfig,
    IngressSubscription,
    JidokaDelegationEvent,
    Message,
    RoomBinding,
    Thread
  }

  @impl true
  def init(_opts) do
    state =
      struct!(__MODULE__, %{
        rooms: :ets.new(:rooms, [:set, :public]),
        participants: :ets.new(:participants, [:set, :public]),
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
        message_external_ids: :ets.new(:message_external_ids, [:set, :public]),
        onboarding_flows: :ets.new(:onboarding_flows, [:set, :public]),
        bridge_configs: :ets.new(:bridge_configs, [:set, :public]),
        ingress_subscriptions: :ets.new(:ingress_subscriptions, [:set, :public]),
        routing_policies: :ets.new(:routing_policies, [:set, :public]),
        jidoka_delegation_events: :ets.new(:jidoka_delegation_events, [:set, :public]),
        jidoka_delegation_cancellations: :ets.new(:jidoka_delegation_cancellations, [:set, :public])
      })

    {:ok, state}
  end

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

    message_ids = :ets.lookup(state.room_messages, room_id) |> Enum.map(&elem(&1, 1))
    Enum.each(message_ids, &delete_message(state, &1))

    {:ok, bindings} = list_room_bindings(state, room_id)
    Enum.each(bindings, &delete_room_binding(state, &1.id))

    delete_threads_for_room(state, room_id)
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
    true = :ets.insert(state.participants, {participant.id, participant})
    {:ok, participant}
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
    true = :ets.delete(state.participants, participant_id)
    :ok
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

  @impl true
  def get_jidoka_delegation_event(state, event_id) when is_binary(event_id) do
    case lookup_jidoka_delegation_event(state, event_id) do
      nil -> {:error, :not_found}
      %JidokaDelegationEvent{} = event -> {:ok, event}
    end
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
      [{^binding_key, participant_id}] ->
        case get_participant(state, participant_id) do
          {:ok, _participant} = ok ->
            ok

          {:error, :not_found} ->
            # Remove stale binding only if it still points at the missing participant.
            true = :ets.delete_object(state.participant_bindings, {binding_key, participant_id})

            get_or_create_participant_by_external_binding(
              state,
              channel,
              bridge_id,
              external_id,
              attrs
            )
        end

      [] ->
        participant = build_bound_participant(channel, external_id, attrs)
        {:ok, participant} = save_participant(state, participant)

        case :ets.insert_new(state.participant_bindings, {binding_key, participant.id}) do
          true ->
            {:ok, participant}

          false ->
            resolve_participant_binding_race(state, binding_key, participant.id)
        end
    end
  end

  @impl true
  def bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) do
    with {:ok, _participant} <- get_participant(state, participant_id) do
      binding_key = participant_binding_key(channel, bridge_id, external_id)

      case :ets.insert_new(state.participant_bindings, {binding_key, participant_id}) do
        true ->
          :ok

        false ->
          case :ets.lookup(state.participant_bindings, binding_key) do
            [{^binding_key, ^participant_id}] ->
              :ok

            [{^binding_key, existing_participant_id}] ->
              {:error, {:external_identity_conflict, existing_participant_id}}
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
      |> Enum.filter(&participant_matches?(&1, query))
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

  def directory_search(_state, target, _query, _opts) do
    {:error, {:invalid_directory_target, target}}
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

  defp participant_matches?(participant, query) do
    id_matches?(participant.id, query) and
      name_matches?(participant_name(participant), query) and
      participant_external_id_matches?(participant, query)
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

  defp ensure_delegation_not_cancelled(state, %JidokaDelegationEvent{} = event) do
    if JidokaDelegationEvent.deliverable?(event) and
         :ets.member(state.jidoka_delegation_cancellations, event.delegation_ref.id) do
      {:error, :jidoka_delegation_cancelled}
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

  defp normalize_term(value) when is_binary(value), do: value
  defp normalize_term(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_term(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_term(value), do: inspect(value)

  defp participant_binding_key(channel, bridge_id, external_id) do
    {channel, normalize_term(bridge_id), normalize_term(external_id)}
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
      [{^binding_key, participant_id}] when participant_id == candidate_participant_id ->
        get_participant(state, participant_id)

      [{^binding_key, participant_id}] ->
        :ok = delete_participant(state, candidate_participant_id)
        get_participant(state, participant_id)

      [] ->
        true = :ets.insert(state.participant_bindings, {binding_key, candidate_participant_id})
        get_participant(state, candidate_participant_id)
    end
  end
end
