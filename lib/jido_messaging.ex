defmodule Jido.Messaging do
  @moduledoc """
  Messaging and notification system for the Jido ecosystem.

  ## Usage

  Define a messaging module in your application:

      defmodule MyApp.Messaging do
        use Jido.Messaging,
          adapter: Jido.Messaging.Adapters.ETS
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

  alias Jido.Chat.{LegacyMessage, Participant, Room}
  alias Jido.Messaging.{ConfigStore, Onboarding, Runtime}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @adapter Keyword.get(opts, :adapter, Jido.Messaging.Adapters.ETS)
      @adapter_opts Keyword.get(opts, :adapter_opts, [])
      @bridge_manifest_paths Keyword.get(opts, :bridge_manifest_paths, [])
      @required_bridges Keyword.get(opts, :required_bridges, [])
      @bridge_collision_policy Keyword.get(opts, :bridge_collision_policy, :prefer_last)
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
        bridge_manifest_paths = Keyword.get(opts, :bridge_manifest_paths, @bridge_manifest_paths)
        required_bridges = Keyword.get(opts, :required_bridges, @required_bridges)
        bridge_collision_policy = Keyword.get(opts, :bridge_collision_policy, @bridge_collision_policy)

        Jido.Messaging.Supervisor.start_link(
          name: __jido_messaging__(:supervisor),
          instance_module: __MODULE__,
          adapter: adapter,
          adapter_opts: adapter_opts,
          bridge_manifest_paths: bridge_manifest_paths,
          required_bridges: required_bridges,
          bridge_collision_policy: bridge_collision_policy
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
          :bridge_registry -> Module.concat(__MODULE__, Registry.Bridges)
          :instance_supervisor -> Module.concat(__MODULE__, InstanceSupervisor)
          :bridge_supervisor -> Module.concat(__MODULE__, BridgeSupervisor)
          :onboarding_registry -> Module.concat(__MODULE__, Registry.Onboarding)
          :onboarding_supervisor -> Module.concat(__MODULE__, OnboardingSupervisor)
          :session_manager_supervisor -> Module.concat(__MODULE__, SessionManagerSupervisor)
          :dead_letter -> Module.concat(__MODULE__, DeadLetter)
          :dead_letter_replay_supervisor -> Module.concat(__MODULE__, DeadLetterReplaySupervisor)
          :config_store -> Module.concat(__MODULE__, ConfigStore)
          :deduper -> Module.concat(__MODULE__, Deduper)
          :adapter -> @adapter
          :adapter_opts -> @adapter_opts
          :bridge_manifest_paths -> @bridge_manifest_paths
          :required_bridges -> @required_bridges
          :bridge_collision_policy -> @bridge_collision_policy
          :pubsub -> @pubsub
        end
      end

      # Delegated API functions

      @doc "Create a new room"
      def create_room(attrs) do
        Jido.Messaging.create_room(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a room by ID"
      def get_room(room_id) do
        Jido.Messaging.get_room(__jido_messaging__(:runtime), room_id)
      end

      @doc "List rooms with optional filters"
      def list_rooms(opts \\ []) do
        Jido.Messaging.list_rooms(__jido_messaging__(:runtime), opts)
      end

      @doc "Delete a room"
      def delete_room(room_id) do
        Jido.Messaging.delete_room(__jido_messaging__(:runtime), room_id)
      end

      @doc "Create a new participant"
      def create_participant(attrs) do
        Jido.Messaging.create_participant(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a participant by ID"
      def get_participant(participant_id) do
        Jido.Messaging.get_participant(__jido_messaging__(:runtime), participant_id)
      end

      @doc "Save a message"
      def save_message(attrs) do
        Jido.Messaging.save_message(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a message by ID"
      def get_message(message_id) do
        Jido.Messaging.get_message(__jido_messaging__(:runtime), message_id)
      end

      @doc "List messages for a room"
      def list_messages(room_id, opts \\ []) do
        Jido.Messaging.list_messages(__jido_messaging__(:runtime), room_id, opts)
      end

      @doc "Delete a message"
      def delete_message(message_id) do
        Jido.Messaging.delete_message(__jido_messaging__(:runtime), message_id)
      end

      @doc "Get or create room by external binding"
      def get_or_create_room_by_external_binding(channel, bridge_id, external_id, attrs \\ %{}) do
        Jido.Messaging.get_or_create_room_by_external_binding(
          __jido_messaging__(:runtime),
          channel,
          bridge_id,
          external_id,
          attrs
        )
      end

      @doc "Get or create participant by external ID"
      def get_or_create_participant_by_external_id(channel, external_id, attrs \\ %{}) do
        Jido.Messaging.get_or_create_participant_by_external_id(
          __jido_messaging__(:runtime),
          channel,
          external_id,
          attrs
        )
      end

      @doc "Get a message by its external ID within a channel/bridge context"
      def get_message_by_external_id(channel, bridge_id, external_id) do
        Jido.Messaging.get_message_by_external_id(
          __jido_messaging__(:runtime),
          channel,
          bridge_id,
          external_id
        )
      end

      @doc "Update a message's external_id"
      def update_message_external_id(message_id, external_id) do
        Jido.Messaging.update_message_external_id(
          __jido_messaging__(:runtime),
          message_id,
          external_id
        )
      end

      @doc "Save an already-constructed message struct (for updates)"
      def save_message_struct(message) do
        Jido.Messaging.save_message_struct(__jido_messaging__(:runtime), message)
      end

      @doc "Save a room struct directly (for custom IDs)"
      def save_room(room) do
        Jido.Messaging.save_room(__jido_messaging__(:runtime), room)
      end

      @doc "Get room by external binding (without creating)"
      def get_room_by_external_binding(channel, bridge_id, external_id) do
        Jido.Messaging.get_room_by_external_binding(
          __jido_messaging__(:runtime),
          channel,
          bridge_id,
          external_id
        )
      end

      @doc "Create a binding between an internal room and an external platform"
      def create_room_binding(room_id, channel, bridge_id, external_id, attrs \\ %{}) do
        Jido.Messaging.create_room_binding(
          __jido_messaging__(:runtime),
          room_id,
          channel,
          bridge_id,
          external_id,
          attrs
        )
      end

      @doc "List all bindings for a room"
      def list_room_bindings(room_id) do
        Jido.Messaging.list_room_bindings(__jido_messaging__(:runtime), room_id)
      end

      @doc "Delete a room binding"
      def delete_room_binding(binding_id) do
        Jido.Messaging.delete_room_binding(__jido_messaging__(:runtime), binding_id)
      end

      # Directory functions

      @doc "Lookup a single directory entry."
      def directory_lookup(target, query, opts \\ []) do
        Jido.Messaging.directory_lookup(__jido_messaging__(:runtime), target, query, opts)
      end

      @doc "Search directory entries."
      def directory_search(target, query, opts \\ []) do
        Jido.Messaging.directory_search(__jido_messaging__(:runtime), target, query, opts)
      end

      # Onboarding functions

      @doc "Start (or resume) an onboarding flow."
      def start_onboarding(attrs, opts \\ []) do
        Jido.Messaging.start_onboarding(__MODULE__, attrs, opts)
      end

      @doc "Advance an onboarding flow."
      def advance_onboarding(onboarding_id, transition, metadata \\ %{}, opts \\ []) do
        Jido.Messaging.advance_onboarding(__MODULE__, onboarding_id, transition, metadata, opts)
      end

      @doc "Resume an onboarding flow."
      def resume_onboarding(onboarding_id) do
        Jido.Messaging.resume_onboarding(__MODULE__, onboarding_id)
      end

      @doc "Cancel an onboarding flow."
      def cancel_onboarding(onboarding_id, metadata \\ %{}, opts \\ []) do
        Jido.Messaging.cancel_onboarding(__MODULE__, onboarding_id, metadata, opts)
      end

      @doc "Complete an onboarding flow."
      def complete_onboarding(onboarding_id, metadata \\ %{}, opts \\ []) do
        Jido.Messaging.complete_onboarding(__MODULE__, onboarding_id, metadata, opts)
      end

      @doc "Fetch onboarding flow state."
      def get_onboarding(onboarding_id) do
        Jido.Messaging.get_onboarding(__MODULE__, onboarding_id)
      end

      @doc "Find the onboarding worker PID for a flow."
      def whereis_onboarding_worker(onboarding_id) do
        Jido.Messaging.whereis_onboarding_worker(__MODULE__, onboarding_id)
      end

      # Room Server functions

      @doc "Start a room server for the given room"
      def start_room_server(room, opts \\ []) do
        Jido.Messaging.RoomSupervisor.start_room(__MODULE__, room, opts)
      end

      @doc "Get or start a room server"
      def get_or_start_room_server(room, opts \\ []) do
        Jido.Messaging.RoomSupervisor.get_or_start_room(__MODULE__, room, opts)
      end

      @doc "Stop a room server"
      def stop_room_server(room_id) do
        Jido.Messaging.RoomSupervisor.stop_room(__MODULE__, room_id)
      end

      @doc "Find a running room server by room ID"
      def whereis_room_server(room_id) do
        Jido.Messaging.RoomServer.whereis(__MODULE__, room_id)
      end

      @doc "List all running room servers"
      def list_room_servers do
        Jido.Messaging.RoomSupervisor.list_rooms(__MODULE__)
      end

      @doc "Count running room servers"
      def count_room_servers do
        Jido.Messaging.RoomSupervisor.count_rooms(__MODULE__)
      end

      # Agent functions

      @doc "Add an agent to a room"
      def add_agent_to_room(room_id, agent_id, agent_config) do
        Jido.Messaging.AgentSupervisor.start_agent(__MODULE__, room_id, agent_id, agent_config)
      end

      @doc "Remove an agent from a room"
      def remove_agent_from_room(room_id, agent_id) do
        Jido.Messaging.AgentSupervisor.stop_agent(__MODULE__, room_id, agent_id)
      end

      @doc "List agents in a room"
      def list_agents_in_room(room_id) do
        Jido.Messaging.AgentSupervisor.list_agents(__MODULE__, room_id)
      end

      @doc "Find a running agent by room and agent ID"
      def whereis_agent(room_id, agent_id) do
        Jido.Messaging.AgentRunner.whereis(__MODULE__, room_id, agent_id)
      end

      @doc "Count running agents"
      def count_agents do
        Jido.Messaging.AgentSupervisor.count_agents(__MODULE__)
      end

      # Instance lifecycle functions

      @doc "Start a new channel instance"
      def start_instance(channel_type, attrs \\ %{}) do
        Jido.Messaging.InstanceSupervisor.start_instance(__MODULE__, channel_type, attrs)
      end

      @doc "Stop an instance"
      def stop_instance(instance_id) do
        Jido.Messaging.InstanceSupervisor.stop_instance(__MODULE__, instance_id)
      end

      @doc "Get instance status"
      def instance_status(instance_id) do
        Jido.Messaging.InstanceSupervisor.instance_status(__MODULE__, instance_id)
      end

      @doc "List all running instances"
      def list_instances do
        Jido.Messaging.InstanceSupervisor.list_instances(__MODULE__)
      end

      @doc "Count running instances"
      def count_instances do
        Jido.Messaging.InstanceSupervisor.count_instances(__MODULE__)
      end

      @doc "List running bridge workers"
      def list_bridges do
        Jido.Messaging.BridgeSupervisor.list_bridges(__MODULE__)
      end

      # Bridge control-plane functions

      @doc "Create or update bridge config."
      def put_bridge_config(attrs) do
        Jido.Messaging.put_bridge_config(__MODULE__, attrs)
      end

      @doc "Fetch bridge config by id."
      def get_bridge_config(bridge_id) do
        Jido.Messaging.get_bridge_config(__MODULE__, bridge_id)
      end

      @doc "List bridge configs."
      def list_bridge_configs(opts \\ []) do
        Jido.Messaging.list_bridge_configs(__MODULE__, opts)
      end

      @doc "Delete bridge config."
      def delete_bridge_config(bridge_id) do
        Jido.Messaging.delete_bridge_config(__MODULE__, bridge_id)
      end

      @doc "Create or update per-room routing policy."
      def put_routing_policy(room_id, attrs) do
        Jido.Messaging.put_routing_policy(__MODULE__, room_id, attrs)
      end

      @doc "Fetch routing policy for room."
      def get_routing_policy(room_id) do
        Jido.Messaging.get_routing_policy(__MODULE__, room_id)
      end

      @doc "Delete routing policy for room."
      def delete_routing_policy(room_id) do
        Jido.Messaging.delete_routing_policy(__MODULE__, room_id)
      end

      # Inbound routing functions

      @doc "Route webhook payload through bridge-config parse/verify path into ingest."
      def route_webhook(bridge_id, payload, opts \\ []) do
        Jido.Messaging.route_webhook(__MODULE__, bridge_id, payload, opts)
      end

      @doc "Route direct payload through bridge-config transform path into ingest."
      def route_payload(bridge_id, payload, opts \\ []) do
        Jido.Messaging.route_payload(__MODULE__, bridge_id, payload, opts)
      end

      # Outbound routing functions

      @doc "Resolve configured outbound adapter routes for a room."
      def resolve_outbound_routes(room_id, opts \\ []) do
        Jido.Messaging.resolve_outbound_routes(__MODULE__, room_id, opts)
      end

      @doc "Route outbound text through bridge bindings/policy for a room."
      def route_outbound(room_id, text, opts \\ []) do
        Jido.Messaging.route_outbound(__MODULE__, room_id, text, opts)
      end

      @doc "Get health snapshot for an instance"
      def instance_health(instance_id) do
        case Jido.Messaging.InstanceServer.whereis(__MODULE__, instance_id) do
          nil -> {:error, :not_found}
          pid -> Jido.Messaging.InstanceServer.health_snapshot(pid)
        end
      end

      @doc "Get health snapshots for all running instances"
      def list_instance_health do
        Jido.Messaging.InstanceSupervisor.list_instance_health(__MODULE__)
      end

      # Deduplication functions

      @doc "Check if a message key is a duplicate (and mark as seen if new)"
      def check_dedupe(key, ttl_ms \\ nil) do
        Jido.Messaging.Deduper.check_and_mark(__MODULE__, key, ttl_ms)
      end

      @doc "Check if a message key has been seen"
      def seen?(key) do
        Jido.Messaging.Deduper.seen?(__MODULE__, key)
      end

      @doc "Clear all dedupe keys"
      def clear_dedupe do
        Jido.Messaging.Deduper.clear(__MODULE__)
      end

      # Dead-letter functions

      @doc "List dead-letter records."
      def list_dead_letters(opts \\ []) do
        Jido.Messaging.DeadLetter.list(__MODULE__, opts)
      end

      @doc "Get a dead-letter record by ID."
      def get_dead_letter(dead_letter_id) do
        Jido.Messaging.DeadLetter.get(__MODULE__, dead_letter_id)
      end

      @doc "Replay a dead-letter record by ID."
      def replay_dead_letter(dead_letter_id, opts \\ []) do
        Jido.Messaging.DeadLetter.replay(__MODULE__, dead_letter_id, opts)
      end

      @doc "Archive a dead-letter record by ID."
      def archive_dead_letter(dead_letter_id) do
        Jido.Messaging.DeadLetter.archive(__MODULE__, dead_letter_id)
      end

      @doc "Purge dead-letter records by filter."
      def purge_dead_letters(opts \\ []) do
        Jido.Messaging.DeadLetter.purge(__MODULE__, opts)
      end

      # PubSub functions

      @doc "Subscribe to room events via PubSub"
      def subscribe(room_id) do
        Jido.Messaging.PubSub.subscribe(__MODULE__, room_id)
      end

      @doc "Unsubscribe from room events"
      def unsubscribe(room_id) do
        Jido.Messaging.PubSub.unsubscribe(__MODULE__, room_id)
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

  @doc "Save a room struct directly (for custom IDs)"
  def save_room(runtime, %Room{} = room) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.save_room(adapter_state, room)
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
    message = LegacyMessage.new(attrs)
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
  def get_or_create_room_by_external_binding(runtime, channel, bridge_id, external_id, attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)

    adapter.get_or_create_room_by_external_binding(
      adapter_state,
      channel,
      bridge_id,
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
  def get_message_by_external_id(runtime, channel, bridge_id, external_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_message_by_external_id(adapter_state, channel, bridge_id, external_id)
  end

  @doc "Update a message's external_id"
  def update_message_external_id(runtime, message_id, external_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.update_message_external_id(adapter_state, message_id, external_id)
  end

  @doc "Save an already-constructed message struct (for updates)"
  def save_message_struct(runtime, %LegacyMessage{} = message) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.save_message(adapter_state, message)
  end

  @doc "Get room by external binding (without creating)"
  def get_room_by_external_binding(runtime, channel, bridge_id, external_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_room_by_external_binding(adapter_state, channel, bridge_id, external_id)
  end

  @doc "Create a binding between an internal room and an external platform"
  def create_room_binding(runtime, room_id, channel, bridge_id, external_id, attrs) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.create_room_binding(adapter_state, room_id, channel, bridge_id, external_id, attrs)
  end

  @doc "List all bindings for a room"
  def list_room_bindings(runtime, room_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.list_room_bindings(adapter_state, room_id)
  end

  @doc "Delete a room binding"
  def delete_room_binding(runtime, binding_id) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.delete_room_binding(adapter_state, binding_id)
  end

  @doc "Lookup a single directory entry."
  def directory_lookup(runtime, target, query, opts \\ [])
      when is_atom(target) and is_map(query) and is_list(opts) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.directory_lookup(adapter_state, target, query, opts)
  end

  @doc "Search directory entries."
  def directory_search(runtime, target, query, opts \\ [])
      when is_atom(target) and is_map(query) and is_list(opts) do
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.directory_search(adapter_state, target, query, opts)
  end

  @doc "Start (or resume) an onboarding flow."
  def start_onboarding(instance_module, attrs, opts \\ [])
      when is_atom(instance_module) and is_map(attrs) and is_list(opts) do
    Onboarding.start(instance_module, attrs, opts)
  end

  @doc "Advance an onboarding flow."
  def advance_onboarding(instance_module, onboarding_id, transition, metadata \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_atom(transition) and is_map(metadata) and
             is_list(opts) do
    Onboarding.advance(instance_module, onboarding_id, transition, metadata, opts)
  end

  @doc "Resume an onboarding flow."
  def resume_onboarding(instance_module, onboarding_id)
      when is_atom(instance_module) and is_binary(onboarding_id) do
    Onboarding.resume(instance_module, onboarding_id)
  end

  @doc "Cancel an onboarding flow."
  def cancel_onboarding(instance_module, onboarding_id, metadata \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_map(metadata) and is_list(opts) do
    Onboarding.cancel(instance_module, onboarding_id, metadata, opts)
  end

  @doc "Complete an onboarding flow."
  def complete_onboarding(instance_module, onboarding_id, metadata \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_map(metadata) and is_list(opts) do
    Onboarding.complete(instance_module, onboarding_id, metadata, opts)
  end

  @doc "Fetch an onboarding flow."
  def get_onboarding(instance_module, onboarding_id)
      when is_atom(instance_module) and is_binary(onboarding_id) do
    Onboarding.get(instance_module, onboarding_id)
  end

  @doc "Find onboarding worker PID."
  def whereis_onboarding_worker(instance_module, onboarding_id)
      when is_atom(instance_module) and is_binary(onboarding_id) do
    Onboarding.whereis_worker(instance_module, onboarding_id)
  end

  @doc "Create or update bridge config."
  def put_bridge_config(instance_module, attrs)
      when is_atom(instance_module) and is_map(attrs) do
    ConfigStore.put_bridge_config(instance_module, attrs)
  end

  @doc "Fetch bridge config by id."
  def get_bridge_config(instance_module, bridge_id)
      when is_atom(instance_module) and is_binary(bridge_id) do
    ConfigStore.get_bridge_config(instance_module, bridge_id)
  end

  @doc "List bridge configs."
  def list_bridge_configs(instance_module, opts \\ [])
      when is_atom(instance_module) and is_list(opts) do
    ConfigStore.list_bridge_configs(instance_module, opts)
  end

  @doc "Delete bridge config."
  def delete_bridge_config(instance_module, bridge_id)
      when is_atom(instance_module) and is_binary(bridge_id) do
    ConfigStore.delete_bridge_config(instance_module, bridge_id)
  end

  @doc "Create or update room routing policy."
  def put_routing_policy(instance_module, room_id, attrs)
      when is_atom(instance_module) and is_binary(room_id) and is_map(attrs) do
    ConfigStore.put_routing_policy(instance_module, room_id, attrs)
  end

  @doc "Fetch room routing policy."
  def get_routing_policy(instance_module, room_id)
      when is_atom(instance_module) and is_binary(room_id) do
    ConfigStore.get_routing_policy(instance_module, room_id)
  end

  @doc "Delete room routing policy."
  def delete_routing_policy(instance_module, room_id)
      when is_atom(instance_module) and is_binary(room_id) do
    ConfigStore.delete_routing_policy(instance_module, room_id)
  end

  @doc "Route webhook payload through bridge-config parse/verify path into ingest."
  def route_webhook(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    Jido.Messaging.InboundRouter.route_webhook(instance_module, bridge_id, payload, opts)
  end

  @doc "Route direct payload through bridge-config transform path into ingest."
  def route_payload(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    Jido.Messaging.InboundRouter.route_payload(instance_module, bridge_id, payload, opts)
  end

  @doc "List running bridge workers for an instance module."
  def list_bridges(instance_module) when is_atom(instance_module) do
    Jido.Messaging.BridgeSupervisor.list_bridges(instance_module)
  end

  @doc "Resolve configured outbound adapter routes for a room."
  def resolve_outbound_routes(instance_module, room_id, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_list(opts) do
    Jido.Messaging.OutboundRouter.resolve_routes(instance_module, room_id, opts)
  end

  @doc "Route outbound text through bridge bindings/policy for a room."
  def route_outbound(instance_module, room_id, text, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_binary(text) and is_list(opts) do
    Jido.Messaging.OutboundRouter.route_outbound(instance_module, room_id, text, opts)
  end
end
