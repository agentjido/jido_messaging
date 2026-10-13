defmodule Jido.Messaging.AgentRunner do
  @moduledoc """
  GenServer that manages an agent's participation in a specific room thread.

  Each assigned thread gets its own AgentRunner process that:
  - Subscribes to room-level `message_added` signals
  - Filters down to one room/thread assignment
  - Invokes the configured handler
  - Delivers replies through `Jido.Messaging.Deliver`
  """

  use GenServer
  require Logger

  alias Jido.Chat.Participant
  alias Jido.Messaging.{Context, Deliver, Events, Message, RoomServer, Signal}
  alias Jido.Messaging.Signal.Identity
  alias Jido.Messaging.Supervisor, as: MessagingSupervisor

  @schema Zoi.struct(
            __MODULE__,
            %{
              room_id: Zoi.string(),
              thread_id: Zoi.string(),
              agent_id: Zoi.string(),
              agent_config: Zoi.map(),
              instance_module: Zoi.any(),
              subscribed: Zoi.boolean() |> Zoi.default(false),
              handled_messages: Zoi.map() |> Zoi.default(%{}),
              handled_order: Zoi.array(Zoi.string()) |> Zoi.default([])
            },
            coerce: false
          )

  @type agent_config :: %{
          required(:agent_id) => String.t(),
          required(:handler) => (map(), map() -> {:reply, String.t()} | :noreply | {:error, term()}),
          required(:name) => String.t(),
          optional(:mention_handles) => [String.t()],
          optional(:trigger) => atom()
        }

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema."
  def schema, do: @schema

  @doc """
  Start an AgentRunner for an assigned room thread.

  Required options:
  - `:room_id`
  - `:thread_id`
  - `:agent_id`
  - `:agent_config`
  - `:instance_module`
  """
  def start_link(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    thread_id = Keyword.fetch!(opts, :thread_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    instance_module = Keyword.fetch!(opts, :instance_module)

    GenServer.start_link(
      __MODULE__,
      opts,
      name: via_tuple(instance_module, room_id, thread_id, agent_id)
    )
  end

  @doc "Generate a registry via tuple."
  def via_tuple(instance_module, room_id, thread_id, agent_id) do
    registry = Module.concat(instance_module, Registry.Agents)
    {:via, Registry, {registry, {room_id, thread_id, agent_id}}}
  end

  @doc "Get current runner state."
  def get_state(server), do: GenServer.call(server, :get_state)

  @doc "Gracefully stop the runner."
  def stop(server), do: GenServer.stop(server, :normal)

  @doc "Check if a thread-scoped agent runner is running."
  def whereis(instance_module, room_id, thread_id, agent_id) do
    registry = Module.concat(instance_module, Registry.Agents)

    case Registry.lookup(registry, {room_id, thread_id, agent_id}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)
    thread_id = Keyword.fetch!(opts, :thread_id)
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_config = Keyword.fetch!(opts, :agent_config)
    instance_module = Keyword.fetch!(opts, :instance_module)

    state =
      struct!(__MODULE__, %{
        room_id: room_id,
        thread_id: thread_id,
        agent_id: agent_id,
        agent_config: agent_config,
        instance_module: instance_module,
        subscribed: false
      })

    register_as_participant(state)
    send(self(), :subscribe)

    Logger.debug("[Jido.Messaging.AgentRunner] Agent #{agent_id} started in room #{room_id} thread #{thread_id}")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:subscribe, state) do
    bus_name = MessagingSupervisor.signal_bus_name(state.instance_module)

    case Jido.Signal.Bus.subscribe(bus_name, "jido.messaging.room.message_added",
           selector: [source: Events.source(state.instance_module), subject: Identity.room_subject(state.room_id)]
         ) do
      {:ok, _subscription_id} ->
        {:noreply, %{state | subscribed: true}}

      {:error, _reason} ->
        Process.send_after(self(), :subscribe, 100)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, signal}, state) do
    {:noreply, handle_signal(signal, state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.debug(
      "[Jido.Messaging.AgentRunner] Agent #{state.agent_id} stopping in room #{state.room_id} thread #{state.thread_id}"
    )

    :ok
  end

  defp handle_signal(%Jido.Signal{type: "jido.messaging.room.message_added"} = signal, state) do
    with {:ok, catalog} <- Jido.Messaging.Runtime.catalog(state.instance_module.__jido_messaging__(:runtime)),
         {:ok, ^signal} <- signal |> Jido.Signal.to_map() |> Jido.Signal.from_map(),
         {:ok, ^signal} <- Jido.Signal.Catalog.validate(catalog, signal),
         {:ok, ^signal} <- Jido.Chat.Signal.Policy.validate(signal),
         true <- signal.source == Events.source(state.instance_module),
         true <- signal.subject == Identity.room_subject(state.room_id),
         message_id when is_binary(message_id) <- signal.data["message_id"],
         false <- Map.has_key?(state.handled_messages, message_id),
         {:ok, %Message{} = message} <- state.instance_module.get_message(message_id),
         true <- should_handle_message?(signal.data["room_id"], message, state),
         room_server when is_pid(room_server) <- RoomServer.whereis(state.instance_module, state.room_id) do
      context = RoomServer.message_context(room_server, message.id)
      context = if match?(%Context{}, context), do: %{context | parent_signal: signal}, else: context
      handle_triggered_message(message, context, state, signal)
      order = [message.id | state.handled_order] |> Enum.take(1_000)
      handled = state.handled_messages |> Map.put(message.id, true) |> Map.take(order)
      %{state | handled_messages: handled, handled_order: order}
    else
      _ -> state
    end
  end

  defp handle_signal(_signal, state), do: state

  defp should_handle_message?(room_id, %Message{} = message, state) do
    room_id == state.room_id and
      message.thread_id == state.thread_id and
      message.sender_id != state.agent_id and not Map.get(message.metadata, :provider_self, false)
  end

  defp handle_triggered_message(message, delivery_context, state, parent) do
    Signal.emit_agent(:triggered, state.instance_module, state.room_id, state.agent_id, %{
      parent_signal: parent,
      message_id: message.id,
      thread_id: state.thread_id
    })

    handler_context = %{
      room_id: state.room_id,
      thread_id: state.thread_id,
      agent_id: state.agent_id,
      agent_name: state.agent_config.name,
      mention_handles: Map.get(state.agent_config, :mention_handles, []),
      instance_module: state.instance_module,
      delivery_context: delivery_context
    }

    Signal.emit_agent(:started, state.instance_module, state.room_id, state.agent_id, %{
      parent_signal: parent,
      message_id: message.id,
      thread_id: state.thread_id
    })

    case invoke_handler(state.agent_config.handler, message, handler_context) do
      {:reply, text} ->
        case send_reply(text, message, delivery_context, state) do
          {:ok, reply_message} ->
            Signal.emit_agent(:completed, state.instance_module, state.room_id, state.agent_id, %{
              parent_signal: parent,
              message_id: message.id,
              thread_id: state.thread_id,
              response: :reply,
              reply_message_id: reply_message.id
            })

          {:error, reason} ->
            Signal.emit_agent(:failed, state.instance_module, state.room_id, state.agent_id, %{
              parent_signal: parent,
              message_id: message.id,
              thread_id: state.thread_id,
              error: inspect(reason)
            })
        end

      :noreply ->
        Signal.emit_agent(:completed, state.instance_module, state.room_id, state.agent_id, %{
          parent_signal: parent,
          message_id: message.id,
          thread_id: state.thread_id,
          response: :noreply
        })

      {:error, reason} ->
        Signal.emit_agent(:failed, state.instance_module, state.room_id, state.agent_id, %{
          parent_signal: parent,
          message_id: message.id,
          thread_id: state.thread_id,
          error: inspect(reason)
        })
    end
  end

  defp invoke_handler(handler, message, context) do
    case handler.(message, context) do
      {:reply, text} when is_binary(text) -> {:reply, text}
      :noreply -> :noreply
      {:error, _} = error -> error
      _ -> {:error, :invalid_handler_result}
    end
  rescue
    _ -> {:error, :agent_failure}
  catch
    _, _ -> {:error, :agent_failure}
  end

  defp send_reply(_text, _message, nil, _state), do: {:error, :missing_delivery_context}

  defp send_reply(text, original_message, %Context{} = delivery_context, state) do
    delivery_context =
      %{
        delivery_context
        | thread_id: state.thread_id,
          external_thread_id: delivery_context.external_thread_id || original_message.external_thread_id,
          delivery_external_room_id:
            delivery_context.delivery_external_room_id || original_message.delivery_external_room_id
      }

    Deliver.deliver_outgoing(state.instance_module, original_message, text, delivery_context,
      sender_id: state.agent_id,
      sender_name: state.agent_config.name
    )
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
      nil -> :ok
      pid -> RoomServer.add_participant(pid, participant)
    end
  end
end
