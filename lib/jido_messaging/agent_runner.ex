defmodule Jido.Messaging.AgentRunner do
  @moduledoc """
  GenServer that manages an agent's participation in a specific room.

  Each agent in a room gets its own AgentRunner process that:
  - Subscribes to Signal Bus for `message_added` events
  - Determines whether to respond based on trigger configuration
  - Calls the agent's handler function to generate responses
  - Emits agent lifecycle signals (triggered, started, completed, failed)

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

  alias Jido.Chat.Participant
  alias Jido.Messaging.{RoomServer, Signal}
  alias Jido.Messaging.Supervisor, as: MessagingSupervisor

  @schema Zoi.struct(
            __MODULE__,
            %{
              room_id: Zoi.string(),
              agent_id: Zoi.string(),
              agent_config: Zoi.map(),
              instance_module: Zoi.any(),
              subscribed: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: false
          )

  @type agent_config :: %{
          handler: (map(), map() -> {:reply, String.t()} | :noreply | {:error, term()}),
          trigger: :all | :mention | {:prefix, String.t()},
          name: String.t()
        }

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

  # Public API

  @doc """
  Start an AgentRunner for an agent in a room.

  Options:
  - `:room_id` - Required. The room this agent participates in
  - `:agent_id` - Required. Unique identifier for this agent
  - `:agent_config` - Required. Configuration map with handler, trigger, and name
  - `:instance_module` - Required. The Jido.Messaging instance module
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

    state =
      struct!(__MODULE__, %{
        room_id: room_id,
        agent_id: agent_id,
        agent_config: agent_config,
        instance_module: instance_module,
        subscribed: false
      })

    register_as_participant(state)

    # Schedule subscription to Signal Bus
    send(self(), :subscribe)

    Logger.debug("[Jido.Messaging.AgentRunner] Agent #{agent_id} started in room #{room_id}")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    bus_name = MessagingSupervisor.signal_bus_name(state.instance_module)

    case Jido.Signal.Bus.subscribe(bus_name, "jido.messaging.room.message_added") do
      {:ok, _subscription_id} ->
        Logger.debug("[AgentRunner] Agent #{state.agent_id} subscribed to Signal Bus")
        {:noreply, %{state | subscribed: true}}

      {:error, reason} ->
        Logger.debug("[AgentRunner] Agent #{state.agent_id} failed to subscribe: #{inspect(reason)}, retrying")
        Process.send_after(self(), :subscribe, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    handle_signal(signal, state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @doc deprecated: "Use Signal Bus subscription instead"
  @impl true
  def handle_cast({:process_message, message}, state) do
    Logger.debug("[AgentRunner] Received deprecated direct process_message cast")

    if should_trigger?(message, state) and not from_self?(message, state) do
      handle_triggered_message(message, state)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.debug("[Jido.Messaging.AgentRunner] Agent #{state.agent_id} stopping in room #{state.room_id}")

    :ok
  end

  # Private functions

  defp handle_signal(%{type: "jido.messaging.room.message_added"} = signal, state) do
    room_id = signal.data.room_id
    message = signal.data.message

    # Only process messages for this agent's room
    if room_id == state.room_id do
      if should_trigger?(message, state) and not from_self?(message, state) do
        handle_triggered_message(message, state)
      end
    end
  end

  defp handle_signal(_signal, _state), do: :ok

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
    # Emit triggered signal
    Signal.emit_agent(:triggered, state.instance_module, state.room_id, state.agent_id, %{
      message_id: message.id,
      trigger: state.agent_config.trigger
    })

    context = %{
      room_id: state.room_id,
      agent_id: state.agent_id,
      agent_name: state.agent_config.name,
      instance_module: state.instance_module
    }

    # Emit started signal
    Signal.emit_agent(:started, state.instance_module, state.room_id, state.agent_id, %{
      message_id: message.id
    })

    case state.agent_config.handler.(message, context) do
      {:reply, text} ->
        case send_reply(text, message, state) do
          {:ok, reply_message} ->
            Signal.emit_agent(:completed, state.instance_module, state.room_id, state.agent_id, %{
              message_id: message.id,
              response: :reply,
              reply_message_id: reply_message.id
            })

          {:error, reason} ->
            Signal.emit_agent(:failed, state.instance_module, state.room_id, state.agent_id, %{
              message_id: message.id,
              error: inspect(reason)
            })
        end

      :noreply ->
        Signal.emit_agent(:completed, state.instance_module, state.room_id, state.agent_id, %{
          message_id: message.id,
          response: :noreply
        })

      {:error, reason} ->
        Logger.warning("[Jido.Messaging.AgentRunner] Handler error for agent #{state.agent_id}: #{inspect(reason)}")

        Signal.emit_agent(:failed, state.instance_module, state.room_id, state.agent_id, %{
          message_id: message.id,
          error: inspect(reason)
        })
    end
  end

  defp send_reply(text, original_message, state) do
    alias Jido.Chat.Content.Text

    message_attrs = %{
      room_id: state.room_id,
      sender_id: state.agent_id,
      role: :assistant,
      content: [%Text{text: text}],
      reply_to_id: original_message.id,
      status: :sent,
      metadata: %{
        channel: :agent,
        username: state.agent_config.name,
        display_name: state.agent_config.name,
        agent_name: state.agent_config.name
      }
    }

    case state.instance_module.save_message(message_attrs) do
      {:ok, message} ->
        add_to_room_server(state, message)

        Logger.debug("[Jido.Messaging.AgentRunner] Agent #{state.agent_id} sent reply in room #{state.room_id}")

        {:ok, message}

      {:error, reason} = error ->
        Logger.warning("[Jido.Messaging.AgentRunner] Failed to save reply: #{inspect(reason)}")

        error
    end
  end

  defp add_to_room_server(state, message) do
    case RoomServer.whereis(state.instance_module, state.room_id) do
      nil ->
        Logger.debug("[Jido.Messaging.AgentRunner] Room server not running for #{state.room_id}, skipping")

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
        Logger.debug("[Jido.Messaging.AgentRunner] Room server not running, skipping participant registration")

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
