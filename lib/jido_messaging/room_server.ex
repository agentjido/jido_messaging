defmodule JidoMessaging.RoomServer do
  @moduledoc """
  GenServer that manages a single room's state.

  Each room has its own process that holds:
  - The Room struct
  - Bounded message history
  - Active participants

  Rooms are started on-demand and hibernate after inactivity.
  """
  use GenServer
  require Logger

  alias JidoMessaging.{Room, Message, Participant}

  @default_message_limit 100
  @default_timeout_ms :timer.minutes(5)

  defstruct [
    :room,
    :instance_module,
    messages: [],
    participants: %{},
    message_limit: @default_message_limit,
    timeout_ms: @default_timeout_ms
  ]

  @type t :: %__MODULE__{
          room: Room.t(),
          instance_module: module(),
          messages: [Message.t()],
          participants: %{String.t() => Participant.t()},
          message_limit: pos_integer(),
          timeout_ms: pos_integer()
        }

  # Public API

  @doc """
  Start a RoomServer for the given room.

  Options:
  - `:room` - Required. The Room struct or room attributes
  - `:instance_module` - Required. The JidoMessaging instance module
  - `:message_limit` - Optional. Max messages to keep (default: 100)
  - `:timeout_ms` - Optional. Inactivity timeout before hibernation (default: 5 min)
  """
  def start_link(opts) do
    room = Keyword.fetch!(opts, :room)
    instance_module = Keyword.fetch!(opts, :instance_module)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(instance_module, room.id))
  end

  @doc "Generate a via tuple for Registry-based process lookup"
  def via_tuple(instance_module, room_id) do
    registry = Module.concat(instance_module, Registry.Rooms)
    {:via, Registry, {registry, room_id}}
  end

  @doc "Get the current room server state"
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Get the room struct"
  def get_room(server) do
    GenServer.call(server, :get_room)
  end

  @doc "Add a message to the room's history"
  def add_message(server, %Message{} = message) do
    GenServer.call(server, {:add_message, message})
  end

  @doc "Add or update a participant in the room"
  def add_participant(server, %Participant{} = participant) do
    GenServer.call(server, {:add_participant, participant})
  end

  @doc "Remove a participant from the room"
  def remove_participant(server, participant_id) do
    GenServer.call(server, {:remove_participant, participant_id})
  end

  @doc """
  Get messages from the room's history.

  Options:
  - `:limit` - Max messages to return (default: all)
  """
  def get_messages(server, opts \\ []) do
    GenServer.call(server, {:get_messages, opts})
  end

  @doc "Get all participants in the room"
  def get_participants(server) do
    GenServer.call(server, :get_participants)
  end

  @doc "Check if a room server is running"
  def whereis(instance_module, room_id) do
    registry = Module.concat(instance_module, Registry.Rooms)

    case Registry.lookup(registry, room_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Get list of agent PIDs participating in a room"
  def get_agent_pids(instance_module, room_id) do
    JidoMessaging.AgentSupervisor.list_agents(instance_module, room_id)
    |> Enum.map(fn {_agent_id, pid} -> pid end)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    room = Keyword.fetch!(opts, :room)
    instance_module = Keyword.fetch!(opts, :instance_module)
    message_limit = Keyword.get(opts, :message_limit, @default_message_limit)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    state = %__MODULE__{
      room: room,
      instance_module: instance_module,
      messages: [],
      participants: %{},
      message_limit: message_limit,
      timeout_ms: timeout_ms
    }

    {:ok, state, timeout_ms}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state, state.timeout_ms}
  end

  @impl true
  def handle_call(:get_room, _from, state) do
    {:reply, state.room, state, state.timeout_ms}
  end

  @impl true
  def handle_call({:add_message, message}, _from, state) do
    messages = [message | state.messages] |> Enum.take(state.message_limit)
    new_state = %{state | messages: messages}

    notify_agents(state.instance_module, state.room.id, message)

    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call({:add_participant, participant}, _from, state) do
    participants = Map.put(state.participants, participant.id, participant)
    new_state = %{state | participants: participants}
    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call({:remove_participant, participant_id}, _from, state) do
    participants = Map.delete(state.participants, participant_id)
    new_state = %{state | participants: participants}
    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call({:get_messages, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)

    messages =
      if limit do
        Enum.take(state.messages, limit)
      else
        state.messages
      end

    {:reply, messages, state, state.timeout_ms}
  end

  @impl true
  def handle_call(:get_participants, _from, state) do
    participants = Map.values(state.participants)
    {:reply, participants, state, state.timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("RoomServer #{state.room.id} hibernating due to inactivity")
    {:noreply, state, :hibernate}
  end

  # Private functions

  defp notify_agents(instance_module, room_id, message) do
    alias JidoMessaging.{AgentRunner, AgentSupervisor}

    AgentSupervisor.list_agents(instance_module, room_id)
    |> Enum.each(fn {_agent_id, pid} ->
      AgentRunner.process_message(pid, message)
    end)
  end
end
