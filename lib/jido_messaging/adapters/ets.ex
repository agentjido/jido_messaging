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
  """

  @behaviour JidoMessaging.Adapter

  alias JidoMessaging.{Room, Participant, Message}

  defstruct [:rooms, :participants, :messages, :room_messages, :room_bindings, :participant_bindings]

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      rooms: :ets.new(:rooms, [:set, :public]),
      participants: :ets.new(:participants, [:set, :public]),
      messages: :ets.new(:messages, [:set, :public]),
      room_messages: :ets.new(:room_messages, [:bag, :public]),
      room_bindings: :ets.new(:room_bindings, [:set, :public]),
      participant_bindings: :ets.new(:participant_bindings, [:set, :public])
    }

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
    {:ok, message}
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
        room =
          Room.new(
            Map.merge(attrs, %{
              external_bindings: %{
                channel => %{instance_id => external_id}
              }
            })
          )

        {:ok, room} = save_room(state, room)
        true = :ets.insert(state.room_bindings, {binding_key, room.id})
        {:ok, room}
    end
  end

  @impl true
  def get_or_create_participant_by_external_id(state, channel, external_id, attrs) do
    binding_key = {channel, external_id}

    case :ets.lookup(state.participant_bindings, binding_key) do
      [{^binding_key, participant_id}] ->
        get_participant(state, participant_id)

      [] ->
        participant =
          Participant.new(
            Map.merge(attrs, %{
              external_ids: %{channel => external_id}
            })
          )

        {:ok, participant} = save_participant(state, participant)
        true = :ets.insert(state.participant_bindings, {binding_key, participant.id})
        {:ok, participant}
    end
  end
end
