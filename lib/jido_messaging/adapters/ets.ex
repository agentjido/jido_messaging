defmodule JidoMessaging.Adapters.ETS do
  @moduledoc """
  In-memory ETS adapter for JidoMessaging.

  Uses anonymous ETS tables for per-instance isolation, enabling
  multiple messaging instances in the same BEAM without conflicts.

  ## Usage

      defmodule MyApp.Messaging do
        use JidoMessaging,
          adapter: JidoMessaging.Adapters.ETS
      end

  ## State Structure

  The adapter state contains table IDs for:
  - `:rooms` - Room records keyed by room_id
  - `:participants` - Participant records keyed by participant_id
  - `:messages` - Message records keyed by message_id
  - `:room_messages` - Index of message_ids by room_id (bag table)
  - `:room_bindings` - External binding to room_id mapping
  - `:participant_bindings` - External ID to participant_id mapping
  - `:onboarding_flows` - Onboarding flow records keyed by onboarding_id
  """

  @behaviour JidoMessaging.Adapter
  @behaviour JidoMessaging.Directory

  @schema Zoi.struct(
            __MODULE__,
            %{
              rooms: Zoi.any(),
              participants: Zoi.any(),
              messages: Zoi.any(),
              room_messages: Zoi.any(),
              room_bindings: Zoi.any(),
              room_bindings_by_room: Zoi.any(),
              room_bindings_by_id: Zoi.any(),
              participant_bindings: Zoi.any(),
              message_external_ids: Zoi.any(),
              onboarding_flows: Zoi.any()
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  alias JidoMessaging.{Room, Participant, Message, RoomBinding}

  @impl true
  def init(_opts) do
    state =
      struct!(__MODULE__, %{
        rooms: :ets.new(:rooms, [:set, :public]),
        participants: :ets.new(:participants, [:set, :public]),
        messages: :ets.new(:messages, [:set, :public]),
        room_messages: :ets.new(:room_messages, [:bag, :public]),
        room_bindings: :ets.new(:room_bindings, [:set, :public]),
        room_bindings_by_room: :ets.new(:room_bindings_by_room, [:bag, :public]),
        room_bindings_by_id: :ets.new(:room_bindings_by_id, [:set, :public]),
        participant_bindings: :ets.new(:participant_bindings, [:set, :public]),
        message_external_ids: :ets.new(:message_external_ids, [:set, :public]),
        onboarding_flows: :ets.new(:onboarding_flows, [:set, :public])
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
    # Also delete associated messages
    message_ids = :ets.lookup(state.room_messages, room_id) |> Enum.map(&elem(&1, 1))
    Enum.each(message_ids, fn msg_id -> :ets.delete(state.messages, msg_id) end)
    true = :ets.delete(state.room_messages, room_id)
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
    index_external_id(state, message)
    {:ok, message}
  end

  defp index_external_id(_state, %Message{external_id: nil}), do: :ok

  defp index_external_id(state, %Message{} = message) do
    channel = get_in(message.metadata, [:channel])
    instance_id = get_in(message.metadata, [:instance_id])

    if channel && instance_id do
      key = {channel, instance_id, message.external_id}
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

    message_ids =
      :ets.lookup(state.room_messages, room_id)
      |> Enum.map(&elem(&1, 1))

    messages =
      message_ids
      |> Enum.flat_map(fn msg_id ->
        case :ets.lookup(state.messages, msg_id) do
          [{^msg_id, msg}] -> [msg]
          [] -> []
        end
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.reverse()

    {:ok, messages}
  end

  @impl true
  def delete_message(state, message_id) do
    case :ets.lookup(state.messages, message_id) do
      [{^message_id, message}] ->
        true = :ets.delete(state.messages, message_id)
        # Remove from room_messages index (bag table - need to delete specific object)
        true = :ets.delete_object(state.room_messages, {message.room_id, message_id})
        :ok

      [] ->
        :ok
    end
  end

  # External binding operations

  @impl true
  def get_or_create_room_by_external_binding(state, channel, instance_id, external_id, attrs) do
    binding_key = {channel, instance_id, external_id}

    case :ets.lookup(state.room_bindings, binding_key) do
      [{^binding_key, room_id}] ->
        get_room(state, room_id)

      [] ->
        room = build_bound_room(channel, instance_id, external_id, attrs)
        {:ok, room} = save_room(state, room)

        case :ets.insert_new(state.room_bindings, {binding_key, room.id}) do
          true ->
            {:ok, room}

          false ->
            resolve_room_binding_race(state, binding_key, room.id)
        end
    end
  end

  @impl true
  def get_or_create_participant_by_external_id(state, channel, external_id, attrs) do
    binding_key = {channel, external_id}

    case :ets.lookup(state.participant_bindings, binding_key) do
      [{^binding_key, participant_id}] ->
        get_participant(state, participant_id)

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
  def get_message_by_external_id(state, channel, instance_id, external_id) do
    key = {channel, instance_id, external_id}

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
        instance_id = get_in(message.metadata, [:instance_id])

        updated_message = %{message | external_id: external_id}
        true = :ets.insert(state.messages, {message_id, updated_message})

        if channel && instance_id do
          key = {channel, instance_id, external_id}
          true = :ets.insert(state.message_external_ids, {key, message_id})
        end

        {:ok, updated_message}

      {:error, :not_found} = error ->
        error
    end
  end

  # Room binding operations

  @impl true
  def get_room_by_external_binding(state, channel, instance_id, external_id) do
    binding_key = {channel, instance_id, external_id}

    case :ets.lookup(state.room_bindings, binding_key) do
      [{^binding_key, room_id}] -> get_room(state, room_id)
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def create_room_binding(state, room_id, channel, instance_id, external_id, attrs) do
    binding_key = {channel, instance_id, external_id}

    binding =
      RoomBinding.new(
        Map.merge(attrs, %{
          room_id: room_id,
          channel: channel,
          instance_id: instance_id,
          external_room_id: external_id
        })
      )

    true = :ets.insert(state.room_bindings, {binding_key, room_id})
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
        binding_key = {binding.channel, binding.instance_id, binding.external_room_id}
        true = :ets.delete(state.room_bindings, binding_key)
        true = :ets.delete(state.room_bindings_by_id, binding_id)
        true = :ets.delete_object(state.room_bindings_by_room, {binding.room_id, binding_id})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # Directory operations

  @impl JidoMessaging.Directory
  def lookup(state, target, query) when is_map(query) do
    directory_lookup(state, target, query, [])
  end

  @impl JidoMessaging.Directory
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

  defp participant_matches?(participant, query) do
    id_matches?(participant.id, query) and
      name_matches?(participant_name(participant), query) and
      participant_external_id_matches?(participant, query)
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
    instance_id = query_value(query, :instance_id)
    external_id = query_value(query, :external_id)

    cond do
      is_nil(channel) and is_nil(instance_id) and is_nil(external_id) ->
        true

      is_nil(channel) or is_nil(instance_id) or is_nil(external_id) ->
        false

      true ->
        expected_channel = normalize_term(channel)
        expected_instance_id = normalize_term(instance_id)
        expected_external_id = normalize_term(external_id)

        :ets.tab2list(state.room_bindings)
        |> Enum.any?(fn {{binding_channel, binding_instance_id, binding_external_id}, binding_room_id} ->
          binding_room_id == room_id and
            normalize_term(binding_channel) == expected_channel and
            normalize_term(binding_instance_id) == expected_instance_id and
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
    String.contains?(String.downcase(value), String.downcase(to_string(expected)))
  end

  defp contains_ci?(_value, _expected), do: false

  defp participant_name(participant) do
    get_in(participant.identity, [:name]) || get_in(participant.identity, ["name"])
  end

  defp query_value(query, key) do
    Map.get(query, key) || Map.get(query, Atom.to_string(key))
  end

  defp normalize_term(value) when is_binary(value), do: value
  defp normalize_term(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_term(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_term(value), do: to_string(value)

  defp build_bound_room(channel, instance_id, external_id, attrs) do
    Room.new(
      Map.merge(attrs, %{
        external_bindings: %{
          channel => %{instance_id => external_id}
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
