defmodule Jido.Messaging.RoomServer do
  @moduledoc """
  GenServer that manages a single room's state.

  Each room has its own process that holds:
  - The Room struct
  - Bounded message history
  - Active participants

  Rooms are started on demand and hibernate after inactivity. On restart, the
  room restores agent specs and thread assignments from live runner Registry
  records. It does not wait for a runner handler or its supervisor. If the
  Registry is temporarily unavailable, a room-owned timer retries the read.
  """
  use GenServer
  require Logger
  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.Message
  @default_message_limit 100
  @default_timeout_ms :timer.minutes(5)
  @default_typing_timeout_ms :timer.seconds(5)
  @restore_retry_ms 100
  @schema Zoi.struct(
            __MODULE__,
            %{
              room: Zoi.struct(Room),
              instance_module: Zoi.any(),
              messages: Zoi.array(Zoi.struct(Message)) |> Zoi.default([]),
              message_contexts: Zoi.map() |> Zoi.default(%{}),
              execution_parent: Zoi.any() |> Zoi.default(nil),
              participants: Zoi.map() |> Zoi.default(%{}),
              registered_agents: Zoi.map() |> Zoi.default(%{}),
              thread_assignments: Zoi.map() |> Zoi.default(%{}),
              typing: Zoi.map() |> Zoi.default(%{}),
              message_limit: Zoi.integer() |> Zoi.default(@default_message_limit),
              timeout_ms: Zoi.integer() |> Zoi.default(@default_timeout_ms),
              typing_timeout_ms: Zoi.integer() |> Zoi.default(@default_typing_timeout_ms)
            },
            coerce: false
          )
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  @doc "Returns the Zoi schema"
  def schema do
    @schema
  end

  @doc "Start a RoomServer for the given room.\n\nOptions:\n- `:room` - Required. The Room struct or room attributes\n- `:instance_module` - Required. The Jido.Messaging instance module\n- `:message_limit` - Optional. Max messages to keep (default: 100)\n- `:timeout_ms` - Optional. Inactivity timeout before hibernation (default: 5 min)\n"
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
  def add_message(server, %Message{} = message, context \\ nil) do
    GenServer.call(server, {:add_message, message, context})
  end

  @doc false
  @spec message_context(GenServer.server(), String.t()) :: Jido.Messaging.Context.t() | nil
  def message_context(server, message_id) do
    GenServer.call(server, {:message_context, message_id})
  end

  @doc "Add or update a participant in the room"
  def add_participant(server, %Participant{} = participant) do
    GenServer.call(server, {:add_participant, participant})
  end

  @doc "Remove a participant from the room"
  def remove_participant(server, participant_id) do
    GenServer.call(server, {:remove_participant, participant_id})
  end

  @doc "Get messages from the room's history.\n\nOptions:\n- `:limit` - Max messages to return (default: all)\n"
  def get_messages(server, opts \\ []) do
    GenServer.call(server, {:get_messages, opts})
  end

  @doc "Get all participants in the room"
  def get_participants(server) do
    GenServer.call(server, :get_participants)
  end

  @doc "Update a participant's presence status"
  def update_presence(server, participant_id, presence)
      when presence in [:online, :away, :busy, :offline] do
    GenServer.call(server, {:update_presence, participant_id, presence})
  end

  @doc "Set typing status for a participant"
  def set_typing(server, participant_id, is_typing, opts \\ []) do
    thread_id = Keyword.get(opts, :thread_id)
    GenServer.call(server, {:set_typing, participant_id, is_typing, thread_id})
  end

  @doc "Get currently typing participants"
  def get_typing(server) do
    GenServer.call(server, :get_typing)
  end

  @doc "Add a reaction to a message"
  def add_reaction(server, message_id, participant_id, reaction) when is_binary(reaction) do
    GenServer.call(server, {:add_reaction, message_id, participant_id, reaction})
  end

  @doc "Remove a reaction from a message"
  def remove_reaction(server, message_id, participant_id, reaction) when is_binary(reaction) do
    GenServer.call(server, {:remove_reaction, message_id, participant_id, reaction})
  end

  @doc "Mark a message as delivered to a participant"
  def mark_delivered(server, message_id, participant_id) do
    GenServer.call(server, {:mark_delivered, message_id, participant_id})
  end

  @doc "Mark a message as read by a participant"
  def mark_read(server, message_id, participant_id) do
    GenServer.call(server, {:mark_read, message_id, participant_id})
  end

  @doc "Register an agent with the room"
  def register_agent(server, agent_spec) when is_map(agent_spec) do
    GenServer.call(server, {:register_agent, agent_spec})
  end

  @doc "Unregister an agent from the room"
  def unregister_agent(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:unregister_agent, agent_id})
  end

  @doc "List registered agents"
  def list_agents(server) do
    GenServer.call(server, :list_agents)
  end

  @doc "Fetch one registered agent"
  def get_agent(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:get_agent, agent_id})
  end

  @doc "Assign a thread to an agent"
  def assign_thread(server, thread_id, agent_id)
      when is_binary(thread_id) and is_binary(agent_id) do
    GenServer.call(server, {:assign_thread, thread_id, agent_id})
  end

  @doc "Unassign a thread"
  def unassign_thread(server, thread_id) when is_binary(thread_id) do
    GenServer.call(server, {:unassign_thread, thread_id})
  end

  @doc "Get thread assignment"
  def thread_assignment(server, thread_id) when is_binary(thread_id) do
    GenServer.call(server, {:thread_assignment, thread_id})
  end

  @doc "List thread assignments"
  def list_thread_assignments(server) do
    GenServer.call(server, :list_thread_assignments)
  end

  @doc "Check if a room server is running"
  def whereis(instance_module, room_id) do
    registry = Module.concat(instance_module, Registry.Rooms)

    case Registry.lookup(registry, room_id) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
        end

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Get list of agent PIDs participating in a room"
  def get_agent_pids(instance_module, room_id) do
    Jido.Messaging.AgentSupervisor.list_agents(instance_module, room_id)
    |> Enum.map(fn {_assignment, pid} -> pid end)
  end

  @doc false
  def execute_change(server, operation, data, %Jido.Signal{} = request) do
    GenServer.call(server, {:execute_change, operation, data, request})
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)

    with {:ok, room} <- initial_room(opts) do
      state =
        struct!(__MODULE__, %{
          room: room,
          instance_module: instance_module,
          message_limit: Keyword.get(opts, :message_limit, @default_message_limit),
          timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        })

      {:ok, state, {:continue, :restore_agents}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initial_room(opts) do
    room = Keyword.fetch!(opts, :room)

    if Keyword.get(opts, :restore_from_persistence, false) do
      runtime = Module.concat(Keyword.fetch!(opts, :instance_module), Runtime)

      case Jido.Messaging.get_room(runtime, room.id) do
        {:ok, stored} -> {:ok, stored}
        {:error, :not_found} -> {:ok, room}
        {:error, _reason} = error -> error
      end
    else
      {:ok, room}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  @impl true
  def handle_continue(:restore_agents, state) do
    restore_agents(state)
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state, state.timeout_ms}
  end

  @impl true
  def handle_call({:execute_change, operation, data, request}, from, state) do
    with {:ok, call} <- command_call(state, operation, data) do
      {:reply, result, next, timeout} = handle_call(call, from, %{state | execution_parent: request})
      {:reply, result, %{next | execution_parent: state.execution_parent}, timeout}
    else
      {:error, _} = error -> {:reply, error, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call(:get_room, _from, state) do
    {:reply, state.room, state, state.timeout_ms}
  end

  @impl true
  def handle_call({:add_message, message, context}, _from, state) do
    messages = [message | state.messages] |> Enum.take(state.message_limit)
    contexts = Map.put(state.message_contexts, message.id, context)
    contexts = Map.take(contexts, Enum.map(messages, & &1.id))
    new_state = %{state | messages: messages, message_contexts: contexts}

    emit_signal(:message_added, state, %{
      room_id: state.room.id,
      message: message,
      sender_id: message.sender_id,
      thread_id: message.thread_id,
      context: context
    })

    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call({:message_context, id}, _from, state) do
    {:reply, state.message_contexts[id], state, state.timeout_ms}
  end

  @impl true
  def handle_call({:add_participant, participant}, _from, state) do
    participants = Map.put(state.participants, participant.id, participant)
    new_state = %{state | participants: participants}
    emit_signal(:participant_joined, state, %{room_id: state.room.id, participant: participant})
    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call({:remove_participant, participant_id}, _from, state) do
    participants = Map.delete(state.participants, participant_id)
    new_state = %{state | participants: participants}

    emit_signal(:participant_left, state, %{
      room_id: state.room.id,
      participant_id: participant_id
    })

    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call({:get_messages, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)
    thread_id = Keyword.get(opts, :thread_id)

    messages =
      state.messages
      |> maybe_filter_messages_by_thread(thread_id)
      |> then(fn filtered ->
        if limit do
          Enum.take(filtered, limit)
        else
          filtered
        end
      end)

    {:reply, messages, state, state.timeout_ms}
  end

  @impl true
  def handle_call(:get_participants, _from, state) do
    participants = Map.values(state.participants)
    {:reply, participants, state, state.timeout_ms}
  end

  @impl true
  def handle_call({:update_presence, participant_id, presence}, _from, state) do
    case Map.get(state.participants, participant_id) do
      nil ->
        {:reply, {:error, :not_found}, state, state.timeout_ms}

      participant ->
        old_presence = participant.presence
        updated = %{participant | presence: presence}
        participants = Map.put(state.participants, participant_id, updated)
        new_state = %{state | participants: participants}

        emit_signal(:presence_changed, state, %{
          participant_id: participant_id,
          from: old_presence,
          to: presence
        })

        {:reply, :ok, new_state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:register_agent, agent_spec}, _from, state) do
    agent_id = Map.fetch!(agent_spec, :agent_id)
    registered_agents = Map.put(state.registered_agents, agent_id, agent_spec)
    {:reply, {:ok, agent_spec}, %{state | registered_agents: registered_agents}, state.timeout_ms}
  end

  @impl true
  def handle_call({:unregister_agent, agent_id}, _from, state) do
    registered_agents = Map.delete(state.registered_agents, agent_id)

    thread_assignments =
      state.thread_assignments
      |> Enum.reject(fn {_thread_id, assigned_agent_id} -> assigned_agent_id == agent_id end)
      |> Map.new()

    {:reply, :ok, %{state | registered_agents: registered_agents, thread_assignments: thread_assignments},
     state.timeout_ms}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    {:reply, Map.values(state.registered_agents), state, state.timeout_ms}
  end

  @impl true
  def handle_call({:get_agent, agent_id}, _from, state) do
    case Map.fetch(state.registered_agents, agent_id) do
      {:ok, agent_spec} -> {:reply, {:ok, agent_spec}, state, state.timeout_ms}
      :error -> {:reply, {:error, :not_found}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:assign_thread, thread_id, agent_id}, _from, state) do
    if Map.has_key?(state.registered_agents, agent_id) do
      thread_assignments = Map.put(state.thread_assignments, thread_id, agent_id)
      {:reply, :ok, %{state | thread_assignments: thread_assignments}, state.timeout_ms}
    else
      {:reply, {:error, :unknown_agent}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:unassign_thread, thread_id}, _from, state) do
    {:reply, :ok, %{state | thread_assignments: Map.delete(state.thread_assignments, thread_id)}, state.timeout_ms}
  end

  @impl true
  def handle_call({:thread_assignment, thread_id}, _from, state) do
    {:reply, Map.get(state.thread_assignments, thread_id), state, state.timeout_ms}
  end

  @impl true
  def handle_call(:list_thread_assignments, _from, state) do
    {:reply, state.thread_assignments, state, state.timeout_ms}
  end

  @impl true
  def handle_call({:set_typing, participant_id, is_typing, thread_id}, _from, state) do
    typing_key = {participant_id, thread_id}

    new_typing =
      if is_typing do
        expires_at = DateTime.add(DateTime.utc_now(), state.typing_timeout_ms, :millisecond)

        Process.send_after(
          self(),
          {:typing_timeout, participant_id, thread_id},
          state.typing_timeout_ms
        )

        Map.put(state.typing, typing_key, expires_at)
      else
        Map.delete(state.typing, typing_key)
      end

    new_state = %{state | typing: new_typing}

    emit_signal(:typing, state, %{
      participant_id: participant_id,
      is_typing: is_typing,
      thread_id: thread_id
    })

    {:reply, :ok, new_state, state.timeout_ms}
  end

  @impl true
  def handle_call(:get_typing, _from, state) do
    now = DateTime.utc_now()

    active_typing =
      state.typing
      |> Enum.filter(fn {_key, expires_at} -> DateTime.compare(expires_at, now) == :gt end)
      |> Enum.map(fn {{participant_id, thread_id}, _} ->
        %{participant_id: participant_id, thread_id: thread_id}
      end)

    {:reply, active_typing, state, state.timeout_ms}
  end

  @impl true
  def handle_call({:add_reaction, message_id, participant_id, reaction}, _from, state) do
    case update_message(state, message_id, fn msg ->
           reactions = msg.reactions
           participants_for_reaction = Map.get(reactions, reaction, [])

           if participant_id in participants_for_reaction do
             {:unchanged, msg}
           else
             new_participants = [participant_id | participants_for_reaction]
             {:ok, %{msg | reactions: Map.put(reactions, reaction, new_participants)}}
           end
         end) do
      {:ok, updated_msg, new_state} ->
        emit_signal(:reaction_added, state, %{
          message_id: message_id,
          participant_id: participant_id,
          reaction: reaction
        })

        {:reply, {:ok, updated_msg}, new_state, state.timeout_ms}

      {:unchanged, _msg, new_state} ->
        {:reply, {:ok, :already_exists}, new_state, state.timeout_ms}

      {:error, reason} ->
        {:reply, {:error, reason}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:remove_reaction, message_id, participant_id, reaction}, _from, state) do
    case update_message(state, message_id, fn msg ->
           reactions = msg.reactions
           participants_for_reaction = Map.get(reactions, reaction, [])

           if participant_id in participants_for_reaction do
             new_participants = List.delete(participants_for_reaction, participant_id)

             new_reactions =
               if new_participants == [] do
                 Map.delete(reactions, reaction)
               else
                 Map.put(reactions, reaction, new_participants)
               end

             {:ok, %{msg | reactions: new_reactions}}
           else
             {:unchanged, msg}
           end
         end) do
      {:ok, updated_msg, new_state} ->
        emit_signal(:reaction_removed, state, %{
          message_id: message_id,
          participant_id: participant_id,
          reaction: reaction
        })

        {:reply, {:ok, updated_msg}, new_state, state.timeout_ms}

      {:unchanged, _msg, new_state} ->
        {:reply, {:ok, :not_found}, new_state, state.timeout_ms}

      {:error, reason} ->
        {:reply, {:error, reason}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:mark_delivered, message_id, participant_id}, _from, state) do
    now = DateTime.utc_now()

    case update_message(state, message_id, fn msg ->
           receipts = msg.receipts
           participant_receipt = Map.get(receipts, participant_id, %{})

           if Map.has_key?(participant_receipt, :delivered_at) do
             {:unchanged, msg}
           else
             new_receipt = Map.put(participant_receipt, :delivered_at, now)
             new_receipts = Map.put(receipts, participant_id, new_receipt)
             updated_msg = %{msg | receipts: new_receipts}
             {:ok, maybe_update_status(updated_msg, state.participants)}
           end
         end) do
      {:ok, updated_msg, new_state} ->
        emit_signal(:message_delivered, state, %{
          message_id: message_id,
          participant_id: participant_id
        })

        {:reply, {:ok, updated_msg}, new_state, state.timeout_ms}

      {:unchanged, _msg, new_state} ->
        {:reply, {:ok, :already_delivered}, new_state, state.timeout_ms}

      {:error, reason} ->
        {:reply, {:error, reason}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:mark_read, message_id, participant_id}, _from, state) do
    now = DateTime.utc_now()

    case update_message(state, message_id, fn msg ->
           receipts = msg.receipts
           participant_receipt = Map.get(receipts, participant_id, %{})

           if Map.has_key?(participant_receipt, :read_at) do
             {:unchanged, msg}
           else
             new_receipt =
               participant_receipt |> Map.put_new(:delivered_at, now) |> Map.put(:read_at, now)

             new_receipts = Map.put(receipts, participant_id, new_receipt)
             updated_msg = %{msg | receipts: new_receipts}
             {:ok, maybe_update_status(updated_msg, state.participants)}
           end
         end) do
      {:ok, updated_msg, new_state} ->
        emit_signal(:message_read, state, %{
          message_id: message_id,
          participant_id: participant_id
        })

        {:reply, {:ok, updated_msg}, new_state, state.timeout_ms}

      {:unchanged, _msg, new_state} ->
        {:reply, {:ok, :already_read}, new_state, state.timeout_ms}

      {:error, reason} ->
        {:reply, {:error, reason}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:create_thread, root_message_id}, _from, state) do
    case update_message(state, root_message_id, fn msg ->
           if msg.thread_id do
             {:unchanged, msg}
           else
             {:ok, %{msg | thread_id: msg.id}}
           end
         end) do
      {:ok, updated_msg, new_state} ->
        emit_signal(:thread_created, state, %{root_message_id: root_message_id})
        {:reply, {:ok, updated_msg}, new_state, state.timeout_ms}

      {:unchanged, msg, new_state} ->
        {:reply, {:ok, msg}, new_state, state.timeout_ms}

      {:error, reason} ->
        {:reply, {:error, reason}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:add_thread_reply, root_message_id, reply}, _from, state) do
    root_exists =
      Enum.any?(state.messages, &(&1.id == root_message_id && &1.thread_id == root_message_id))

    if root_exists do
      reply_with_thread = %{reply | thread_id: root_message_id}
      messages = [reply_with_thread | state.messages] |> Enum.take(state.message_limit)
      contexts = Map.take(state.message_contexts, Enum.map(messages, & &1.id))
      new_state = %{state | messages: messages, message_contexts: contexts}

      emit_signal(:message_added, state, %{
        room_id: state.room.id,
        message: reply_with_thread,
        sender_id: reply_with_thread.sender_id
      })

      emit_signal(:thread_reply_added, state, %{
        root_message_id: root_message_id,
        message_id: reply_with_thread.id
      })

      {:reply, {:ok, reply_with_thread}, new_state, state.timeout_ms}
    else
      {:reply, {:error, :thread_not_found}, state, state.timeout_ms}
    end
  end

  @impl true
  def handle_call({:get_thread_messages, root_message_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)

    thread_messages =
      state.messages
      |> Enum.filter(&(&1.thread_id == root_message_id))
      |> then(fn msgs ->
        if limit do
          Enum.take(msgs, limit)
        else
          msgs
        end
      end)

    {:reply, thread_messages, state, state.timeout_ms}
  end

  @impl true
  def handle_info({:typing_timeout, participant_id, thread_id}, state) do
    typing_key = {participant_id, thread_id}
    now = DateTime.utc_now()

    case Map.get(state.typing, typing_key) do
      nil ->
        {:noreply, state, state.timeout_ms}

      expires_at ->
        if DateTime.compare(expires_at, now) != :gt do
          new_typing = Map.delete(state.typing, typing_key)
          new_state = %{state | typing: new_typing}

          Jido.Messaging.Signal.emit(
            :typing,
            state.instance_module,
            state.room.id,
            Map.put(%{participant_id: participant_id, thread_id: thread_id}, :typing, false)
          )

          {:noreply, new_state, state.timeout_ms}
        else
          {:noreply, state, state.timeout_ms}
        end
    end
  end

  @impl true
  def handle_info(:restore_agents, state) do
    restore_agents(state)
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("RoomServer #{state.room.id} hibernating due to inactivity")
    {:noreply, state, :hibernate}
  end

  defp restore_agents(state) do
    case runner_records(state.instance_module, state.room.id) do
      {:ok, records} ->
        supervisor = Process.whereis(Module.concat(state.instance_module, :AgentSupervisor))

        restored =
          Enum.reduce(records, state, fn
            {thread_id, agent_id, pid, {:agent_runner, owner, config}}, current
            when is_pid(pid) and is_pid(owner) and is_map(config) ->
              if Process.alive?(pid) and Process.alive?(owner) and (is_nil(supervisor) or supervisor == owner) do
                spec = config |> Map.put(:agent_id, agent_id) |> Map.put_new(:name, agent_id)

                %{
                  current
                  | registered_agents: Map.put_new(current.registered_agents, agent_id, spec),
                    thread_assignments: Map.put_new(current.thread_assignments, thread_id, agent_id)
                }
              else
                current
              end

            _other, current ->
              current
          end)

        {:noreply, restored, restored.timeout_ms}

      {:error, :registry_unavailable} ->
        Process.send_after(self(), :restore_agents, @restore_retry_ms)
        {:noreply, state, state.timeout_ms}
    end
  end

  defp runner_records(instance_module, room_id) do
    registry = Module.concat(instance_module, Registry.Agents)

    records =
      Registry.select(registry, [
        {{{room_id, :"$1", :"$2"}, :"$3", :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}
      ])

    {:ok, records}
  rescue
    ArgumentError -> {:error, :registry_unavailable}
  catch
    :exit, _reason -> {:error, :registry_unavailable}
  end

  defp command_call(state, "participant_joined", data) do
    runtime = state.instance_module.__jido_messaging__(:runtime)

    with {:ok, participant} <- Jido.Messaging.get_participant(runtime, data["participant_id"]),
         do: {:ok, {:add_participant, participant}}
  end

  defp command_call(_state, "participant_left", data), do: {:ok, {:remove_participant, data["participant_id"]}}

  defp command_call(_state, "set_presence", data),
    do:
      {:ok,
       {:update_presence, data["participant_id"],
        Enum.find([:online, :away, :busy, :offline], &(Atom.to_string(&1) == data["presence"]))}}

  defp command_call(_state, "set_typing", data),
    do: {:ok, {:set_typing, data["participant_id"], data["typing"], data["thread_id"]}}

  defp command_call(_state, operation, data) when operation in ["add_room_reaction", "remove_room_reaction"] do
    name = if operation == "add_room_reaction", do: :add_reaction, else: :remove_reaction
    {:ok, {name, data["message_id"], data["participant_id"], data["reaction"]}}
  end

  defp command_call(_state, operation, data) when operation in ["mark_delivered", "mark_read"] do
    name = if operation == "mark_delivered", do: :mark_delivered, else: :mark_read
    {:ok, {name, data["message_id"], data["participant_id"]}}
  end

  defp command_call(_state, _operation, _data), do: {:error, :invalid_request}

  defp update_message(state, message_id, update_fn) do
    with {:ok, working} <- command_message(state, message_id),
         index when not is_nil(index) <- Enum.find_index(working.messages, &(&1.id == message_id)) do
      msg = Enum.at(working.messages, index)

      case update_fn.(msg) do
        {:ok, updated_msg} ->
          with {:ok, stored} <- persist_command_message(working, updated_msg) do
            messages = List.replace_at(working.messages, index, stored)
            {:ok, stored, %{working | messages: messages}}
          end

        {:unchanged, msg} ->
          {:unchanged, msg, working}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp command_message(%{execution_parent: nil} = state, _id), do: {:ok, state}

  defp command_message(state, id) do
    runtime = state.instance_module.__jido_messaging__(:runtime)

    with {:ok, message} <- Jido.Messaging.get_message(runtime, id),
         true <- message.room_id == state.room.id do
      messages = [message | Enum.reject(state.messages, &(&1.id == id))] |> Enum.take(state.message_limit)
      contexts = Map.take(state.message_contexts, Enum.map(messages, & &1.id))
      {:ok, %{state | messages: messages, message_contexts: contexts}}
    else
      false -> {:error, :room_mismatch}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp persist_command_message(%{execution_parent: nil}, message), do: {:ok, message}

  defp persist_command_message(state, message) do
    runtime = state.instance_module.__jido_messaging__(:runtime)
    Jido.Messaging.save_message_struct(runtime, %{message | updated_at: DateTime.utc_now()})
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp maybe_filter_messages_by_thread(messages, nil) do
    messages
  end

  defp maybe_filter_messages_by_thread(messages, thread_id) do
    Enum.filter(messages, &(&1.thread_id == thread_id))
  end

  defp maybe_update_status(message, participants) do
    recipients = participants |> Map.keys() |> Enum.reject(&(&1 == message.sender_id))

    if Enum.empty?(recipients) do
      message
    else
      receipts = message.receipts

      all_read =
        Enum.all?(recipients, fn pid ->
          case Map.get(receipts, pid) do
            %{read_at: read_at} when not is_nil(read_at) -> true
            _ -> false
          end
        end)

      all_delivered =
        Enum.all?(recipients, fn pid ->
          case Map.get(receipts, pid) do
            %{delivered_at: delivered_at} when not is_nil(delivered_at) -> true
            _ -> false
          end
        end)

      new_status =
        cond do
          all_read -> :read
          all_delivered -> :delivered
          true -> message.status
        end

      %{message | status: new_status}
    end
  end

  defp emit_signal(event_type, state, data) do
    data = if state.execution_parent, do: Map.put(data, :parent_signal, state.execution_parent), else: data
    Jido.Messaging.Signal.emit(event_type, state.instance_module, state.room.id, data)
  end
end
