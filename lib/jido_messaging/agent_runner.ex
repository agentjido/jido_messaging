defmodule JidoMessaging.AgentRunner do
  @moduledoc """
  GenServer that manages an agent's participation in a specific room.

  Each agent in a room gets its own AgentRunner process that:
  - Listens for messages in the room
  - Determines whether to respond based on trigger configuration
  - Calls the agent's handler function to generate responses
  - Sends responses via the Deliver module

  ## Agent Configuration

  The `agent_config` map supports:
  - `:handler` - Function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:trigger` - When to respond: `:all` | `:mention` | `{:prefix, "/cmd"}`
  - `:name` - Display name for the agent

  ## Usage

      config = %{
        name: "EchoBot",
        trigger: :all,
        handler: fn message, _context ->
          {:reply, "Echo: " <> get_text(message)}
        end
      }

      {:ok, pid} = AgentRunner.start_link(
        room_id: room.id,
        agent_id: "echo_bot",
        agent_config: config,
        instance_module: MyApp.Messaging
      )
  """
  use GenServer
  require Logger

  alias JidoMessaging.{Participant, RoomServer}

  defstruct [
    :room_id,
    :agent_id,
    :agent_config,
    :instance_module
  ]

  @type agent_config :: %{
          handler: (map(), map() -> {:reply, String.t()} | :noreply | {:error, term()}),
          trigger: :all | :mention | {:prefix, String.t()},
          name: String.t()
        }

  @type t :: %__MODULE__{
          room_id: String.t(),
          agent_id: String.t(),
          agent_config: agent_config(),
          instance_module: module()
        }

  # Public API

  @doc """
  Start an AgentRunner for an agent in a room.

  Options:
  - `:room_id` - Required. The room this agent participates in
  - `:agent_id` - Required. Unique identifier for this agent
  - `:agent_config` - Required. Configuration map with handler, trigger, and name
  - `:instance_module` - Required. The JidoMessaging instance module
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    instance_module = Keyword.fetch!(opts, :instance_module)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(instance_module, room_id, agent_id))
  end

  @doc "Generate a via tuple for Registry-based process lookup"
  def via_tuple(instance_module, room_id, agent_id) do
    registry = Module.concat(instance_module, Registry.Agents)
    {:via, Registry, {registry, {room_id, agent_id}}}
  end

  @doc """
  Process a new message in the room.

  Called by RoomServer when a message is added. The AgentRunner will:
  1. Check if the message matches the trigger configuration
  2. Call the handler if triggered
  3. Send a reply via Deliver if the handler returns {:reply, text}
  """
  def process_message(server, message) do
    GenServer.cast(server, {:process_message, message})
  end

  @doc "Gracefully stop the agent runner"
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @doc "Get the current state of the agent runner"
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Check if an agent runner is running"
  def whereis(instance_module, room_id, agent_id) do
    registry = Module.concat(instance_module, Registry.Agents)

    case Registry.lookup(registry, {room_id, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_config = Keyword.fetch!(opts, :agent_config)
    instance_module = Keyword.fetch!(opts, :instance_module)

    state = %__MODULE__{
      room_id: room_id,
      agent_id: agent_id,
      agent_config: agent_config,
      instance_module: instance_module
    }

    register_as_participant(state)

    Logger.debug("[JidoMessaging.AgentRunner] Agent #{agent_id} started in room #{room_id}")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:process_message, message}, state) do
    if should_trigger?(message, state) and not from_self?(message, state) do
      handle_triggered_message(message, state)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.debug("[JidoMessaging.AgentRunner] Agent #{state.agent_id} stopping in room #{state.room_id}")

    :ok
  end

  # Private functions

  defp should_trigger?(message, state) do
    case state.agent_config.trigger do
      :all ->
        true

      :mention ->
        agent_name = state.agent_config.name
        text = extract_text(message)
        String.contains?(text, "@#{agent_name}")

      {:prefix, prefix} ->
        text = extract_text(message)
        String.starts_with?(text, prefix)
    end
  end

  defp from_self?(message, state) do
    message.sender_id == state.agent_id
  end

  defp handle_triggered_message(message, state) do
    context = %{
      room_id: state.room_id,
      agent_id: state.agent_id,
      agent_name: state.agent_config.name,
      instance_module: state.instance_module
    }

    case state.agent_config.handler.(message, context) do
      {:reply, text} ->
        send_reply(text, message, state)

      :noreply ->
        :ok

      {:error, reason} ->
        Logger.warning("[JidoMessaging.AgentRunner] Handler error for agent #{state.agent_id}: #{inspect(reason)}")
    end
  end

  defp send_reply(text, original_message, state) do
    alias JidoMessaging.Content.Text

    message_attrs = %{
      room_id: state.room_id,
      sender_id: state.agent_id,
      role: :assistant,
      content: [%Text{text: text}],
      reply_to_id: original_message.id,
      status: :sent,
      metadata: %{agent_name: state.agent_config.name}
    }

    case state.instance_module.save_message(message_attrs) do
      {:ok, message} ->
        add_to_room_server(state, message)

        Logger.debug("[JidoMessaging.AgentRunner] Agent #{state.agent_id} sent reply in room #{state.room_id}")

        {:ok, message}

      {:error, reason} = error ->
        Logger.warning("[JidoMessaging.AgentRunner] Failed to save reply: #{inspect(reason)}")

        error
    end
  end

  defp add_to_room_server(state, message) do
    case RoomServer.whereis(state.instance_module, state.room_id) do
      nil ->
        Logger.debug("[JidoMessaging.AgentRunner] Room server not running for #{state.room_id}, skipping")

      pid ->
        RoomServer.add_message(pid, message)
    end
  end

  defp register_as_participant(state) do
    participant =
      Participant.new(%{
        id: state.agent_id,
        type: :agent,
        identity: %{name: state.agent_config.name},
        presence: :online
      })

    case RoomServer.whereis(state.instance_module, state.room_id) do
      nil ->
        Logger.debug("[JidoMessaging.AgentRunner] Room server not running, skipping participant registration")

      pid ->
        RoomServer.add_participant(pid, participant)
    end
  end

  defp extract_text(message) do
    message.content
    |> Enum.filter(fn
      %{text: _} -> true
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map(fn content -> Map.get(content, :text, "") end)
    |> Enum.join(" ")
  end
end
