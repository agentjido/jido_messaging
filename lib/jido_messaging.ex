defmodule JidoMessaging do
  @moduledoc """
  Messaging and notification system for the Jido ecosystem.

  ## Usage

  Define a messaging module in your application:

      defmodule MyApp.Messaging do
        use JidoMessaging,
          adapter: JidoMessaging.Adapters.ETS
      end

  Add it to your supervision tree:

      children = [
        MyApp.Messaging
      ]

  Use the API:

      {:ok, room} = MyApp.Messaging.create_room(%{type: :direct, name: "Chat"})
      {:ok, message} = MyApp.Messaging.save_message(%{
        room_id: room.id,
        sender_id: "user_123",
        role: :user,
        content: [%{type: :text, text: "Hello!"}]
      })
      {:ok, messages} = MyApp.Messaging.list_messages(room.id)
  """

  alias JidoMessaging.{Room, Message, Participant, Runtime}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @adapter Keyword.get(opts, :adapter, JidoMessaging.Adapters.ETS)
      @adapter_opts Keyword.get(opts, :adapter_opts, [])
      @pubsub Keyword.get(opts, :pubsub)

      def child_spec(init_opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        adapter = Keyword.get(opts, :adapter, @adapter)
        adapter_opts = Keyword.get(opts, :adapter_opts, @adapter_opts)

        JidoMessaging.Supervisor.start_link(
          name: __jido_messaging__(:supervisor),
          instance_module: __MODULE__,
          adapter: adapter,
          adapter_opts: adapter_opts
        )
      end

      @doc "Returns naming info for this instance"
      def __jido_messaging__(key) do
        case key do
          :supervisor -> Module.concat(__MODULE__, :Supervisor)
          :runtime -> Module.concat(__MODULE__, :Runtime)
          :room_registry -> Module.concat(__MODULE__, Registry.Rooms)
          :room_supervisor -> Module.concat(__MODULE__, RoomSupervisor)
          :agent_registry -> Module.concat(__MODULE__, Registry.Agents)
          :agent_supervisor -> Module.concat(__MODULE__, AgentSupervisor)
          :instance_registry -> Module.concat(__MODULE__, Registry.Instances)
          :instance_supervisor -> Module.concat(__MODULE__, InstanceSupervisor)
          :deduper -> Module.concat(__MODULE__, Deduper)
          :adapter -> @adapter
          :adapter_opts -> @adapter_opts
          :pubsub -> @pubsub
        end
      end

      # Delegated API functions

      @doc "Create a new room"
      def create_room(attrs) do
        JidoMessaging.create_room(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a room by ID"
      def get_room(room_id) do
        JidoMessaging.get_room(__jido_messaging__(:runtime), room_id)
      end

      @doc "List rooms with optional filters"
      def list_rooms(opts \\ []) do
        JidoMessaging.list_rooms(__jido_messaging__(:runtime), opts)
      end

      @doc "Delete a room"
      def delete_room(room_id) do
        JidoMessaging.delete_room(__jido_messaging__(:runtime), room_id)
      end

      @doc "Create a new participant"
      def create_participant(attrs) do
        JidoMessaging.create_participant(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a participant by ID"
      def get_participant(participant_id) do
        JidoMessaging.get_participant(__jido_messaging__(:runtime), participant_id)
      end

      @doc "Save a message"
      def save_message(attrs) do
        JidoMessaging.save_message(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a message by ID"
      def get_message(message_id) do
        JidoMessaging.get_message(__jido_messaging__(:runtime), message_id)
      end

      @doc "List messages for a room"
      def list_messages(room_id, opts \\ []) do
        JidoMessaging.list_messages(__jido_messaging__(:runtime), room_id, opts)
      end

      @doc "Delete a message"
      def delete_message(message_id) do
        JidoMessaging.delete_message(__jido_messaging__(:runtime), message_id)
      end

      @doc "Get or create room by external binding"
      def get_or_create_room_by_external_binding(channel, instance_id, external_id, attrs \\ %{}) do
        JidoMessaging.get_or_create_room_by_external_binding(
          __jido_messaging__(:runtime),
          channel,
          instance_id,
          external_id,
          attrs
        )
      end

      @doc "Get or create participant by external ID"
      def get_or_create_participant_by_external_id(channel, external_id, attrs \\ %{}) do
        JidoMessaging.get_or_create_participant_by_external_id(
          __jido_messaging__(:runtime),
          channel,
          external_id,
          attrs
        )
      end

      @doc "Get a message by its external ID within a channel/instance context"
      def get_message_by_external_id(channel, instance_id, external_id) do
        JidoMessaging.get_message_by_external_id(
          __jido_messaging__(:runtime),
          channel,
          instance_id,
          external_id
        )
      end

      @doc "Update a message's external_id"
      def update_message_external_id(message_id, external_id) do
        JidoMessaging.update_message_external_id(
          __jido_messaging__(:runtime),
          message_id,
          external_id
        )
      end

      @doc "Save an already-constructed message struct (for updates)"
      def save_message_struct(message) do
        JidoMessaging.save_message_struct(__jido_messaging__(:runtime), message)
      end

      # Room Server functions

      @doc "Start a room server for the given room"
      def start_room_server(room, opts \\ []) do
        JidoMessaging.RoomSupervisor.start_room(__MODULE__, room, opts)
      end

      @doc "Get or start a room server"
      def get_or_start_room_server(room, opts \\ []) do
        JidoMessaging.RoomSupervisor.get_or_start_room(__MODULE__, room, opts)
      end

      @doc "Stop a room server"
      def stop_room_server(room_id) do
        JidoMessaging.RoomSupervisor.stop_room(__MODULE__, room_id)
      end

      @doc "Find a running room server by room ID"
      def whereis_room_server(room_id) do
        JidoMessaging.RoomServer.whereis(__MODULE__, room_id)
      end

      @doc "List all running room servers"
      def list_room_servers do
        JidoMessaging.RoomSupervisor.list_rooms(__MODULE__)
      end

      @doc "Count running room servers"
      def count_room_servers do
        JidoMessaging.RoomSupervisor.count_rooms(__MODULE__)
      end

      # Agent functions

      @doc "Add an agent to a room"
      def add_agent_to_room(room_id, agent_id, agent_config) do
        JidoMessaging.AgentSupervisor.start_agent(__MODULE__, room_id, agent_id, agent_config)
      end

      @doc "Remove an agent from a room"
      def remove_agent_from_room(room_id, agent_id) do
        JidoMessaging.AgentSupervisor.stop_agent(__MODULE__, room_id, agent_id)
      end

      @doc "List agents in a room"
      def list_agents_in_room(room_id) do
        JidoMessaging.AgentSupervisor.list_agents(__MODULE__, room_id)
      end

      @doc "Find a running agent by room and agent ID"
      def whereis_agent(room_id, agent_id) do
        JidoMessaging.AgentRunner.whereis(__MODULE__, room_id, agent_id)
      end

      @doc "Count running agents"
      def count_agents do
        JidoMessaging.AgentSupervisor.count_agents(__MODULE__)
      end

      # Instance lifecycle functions

      @doc "Start a new channel instance"
      def start_instance(channel_type, attrs \\ %{}) do
        JidoMessaging.InstanceSupervisor.start_instance(__MODULE__, channel_type, attrs)
      end

      @doc "Stop an instance"
      def stop_instance(instance_id) do
        JidoMessaging.InstanceSupervisor.stop_instance(__MODULE__, instance_id)
      end

      @doc "Get instance status"
      def instance_status(instance_id) do
        JidoMessaging.InstanceSupervisor.instance_status(__MODULE__, instance_id)
      end

      @doc "List all running instances"
      def list_instances do
        JidoMessaging.InstanceSupervisor.list_instances(__MODULE__)
      end

      @doc "Count running instances"
      def count_instances do
        JidoMessaging.InstanceSupervisor.count_instances(__MODULE__)
      end

      @doc "Get health snapshot for an instance"
      def instance_health(instance_id) do
        case JidoMessaging.InstanceServer.whereis(__MODULE__, instance_id) do
          nil -> {:error, :not_found}
          pid -> JidoMessaging.InstanceServer.health_snapshot(pid)
        end
      end

      @doc "Get health snapshots for all running instances"
      def list_instance_health do
        JidoMessaging.InstanceSupervisor.list_instance_health(__MODULE__)
      end

      # Deduplication functions

      @doc "Check if a message key is a duplicate (and mark as seen if new)"
      def check_dedupe(key, ttl_ms \\ nil) do
        JidoMessaging.Deduper.check_and_mark(__MODULE__, key, ttl_ms)
      end

      @doc "Check if a message key has been seen"
      def seen?(key) do
        JidoMessaging.Deduper.seen?(__MODULE__, key)
      end

      @doc "Clear all dedupe keys"
      def clear_dedupe do
        JidoMessaging.Deduper.clear(__MODULE__)
      end

      # PubSub functions

      @doc "Subscribe to room events via PubSub"
      def subscribe(room_id) do
        JidoMessaging.PubSub.subscribe(__MODULE__, room_id)
      end

      @doc "Unsubscribe from room events"
      def unsubscribe(room_id) do
        JidoMessaging.PubSub.unsubscribe(__MODULE__, room_id)
      end
    end
  end

  # Core API implementations that work with the Runtime

  @doc "Create a new room"
  def create_room(runtime, attrs) when is_map(attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    room = Room.new(attrs)
    adapter.save_room(adapter_state, room)
  end

  @doc "Get a room by ID"
  def get_room(runtime, room_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_room(adapter_state, room_id)
  end

  @doc "List rooms"
  def list_rooms(runtime, opts \\ []) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.list_rooms(adapter_state, opts)
  end

  @doc "Delete a room"
  def delete_room(runtime, room_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.delete_room(adapter_state, room_id)
  end

  @doc "Create a new participant"
  def create_participant(runtime, attrs) when is_map(attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    participant = Participant.new(attrs)
    adapter.save_participant(adapter_state, participant)
  end

  @doc "Get a participant by ID"
  def get_participant(runtime, participant_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_participant(adapter_state, participant_id)
  end

  @doc "Save a message"
  def save_message(runtime, attrs) when is_map(attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    message = Message.new(attrs)
    adapter.save_message(adapter_state, message)
  end

  @doc "Get a message by ID"
  def get_message(runtime, message_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_message(adapter_state, message_id)
  end

  @doc "List messages for a room"
  def list_messages(runtime, room_id, opts \\ []) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_messages(adapter_state, room_id, opts)
  end

  @doc "Delete a message"
  def delete_message(runtime, message_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.delete_message(adapter_state, message_id)
  end

  @doc "Get or create room by external binding"
  def get_or_create_room_by_external_binding(runtime, channel, instance_id, external_id, attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)

    adapter.get_or_create_room_by_external_binding(
      adapter_state,
      channel,
      instance_id,
      external_id,
      attrs
    )
  end

  @doc "Get or create participant by external ID"
  def get_or_create_participant_by_external_id(runtime, channel, external_id, attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_or_create_participant_by_external_id(adapter_state, channel, external_id, attrs)
  end

  @doc "Get a message by its external ID within a channel/instance context"
  def get_message_by_external_id(runtime, channel, instance_id, external_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_message_by_external_id(adapter_state, channel, instance_id, external_id)
  end

  @doc "Update a message's external_id"
  def update_message_external_id(runtime, message_id, external_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.update_message_external_id(adapter_state, message_id, external_id)
  end

  @doc "Save an already-constructed message struct (for updates)"
  def save_message_struct(runtime, %Message{} = message) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.save_message(adapter_state, message)
  end
end
