defmodule Jido.Messaging do
  @moduledoc """
  Messaging and notification system for the Jido ecosystem.

  ## Usage

  Define a messaging module in your application:

      defmodule MyApp.Messaging do
        use Jido.Messaging,
          persistence: Jido.Messaging.Persistence.ETS
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

  For app-level chat commands that should notify realtime consumers, use the
  eventful command APIs:

      {:ok, result} = MyApp.Messaging.post_message(%{
        room_id: room.id,
        sender_id: "user_123",
        role: :user,
        content: [%{type: :text, text: "Hello!"}]
      })

      [%Jido.Signal{type: "jido.messaging.room.message_added"}] = result.signals

  `save_message/1` remains the low-level persistence primitive. `post_message/2`
  persists and emits committed `jido.messaging.*` CloudEvents through the
  instance Signal Bus.
  """

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.BridgeRoomSpec
  alias Jido.Messaging.TopologyValidator

  alias Jido.Messaging.{
    AccessControl,
    AgentRunner,
    AgentSupervisor,
    ConfigStore,
    IngressSubscriptions,
    Message,
    Onboarding,
    RoomServer,
    RoomSupervisor,
    Runtime,
    Thread
  }

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @persistence Keyword.get(opts, :persistence, Jido.Messaging.Persistence.ETS)
      @persistence_opts Keyword.get(opts, :persistence_opts, [])
      @runtime_profile Keyword.get(opts, :runtime_profile, :full)
      @runtime_features Keyword.get(opts, :runtime_features, [])
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
        persistence = Keyword.get(opts, :persistence, @persistence)
        persistence_opts = Keyword.get(opts, :persistence_opts, @persistence_opts)
        runtime_profile = Keyword.get(opts, :runtime_profile, @runtime_profile)
        runtime_features = Keyword.get(opts, :runtime_features, @runtime_features)
        bridge_manifest_paths = Keyword.get(opts, :bridge_manifest_paths, @bridge_manifest_paths)
        required_bridges = Keyword.get(opts, :required_bridges, @required_bridges)
        bridge_collision_policy = Keyword.get(opts, :bridge_collision_policy, @bridge_collision_policy)

        Jido.Messaging.Supervisor.start_link(
          name: __jido_messaging__(:supervisor),
          instance_module: __MODULE__,
          persistence: persistence,
          persistence_opts: persistence_opts,
          runtime_profile: runtime_profile,
          runtime_features: runtime_features,
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
          :room_registry -> Module.concat([__MODULE__, "Registry", "Rooms"])
          :room_supervisor -> Module.concat(__MODULE__, :RoomSupervisor)
          :agent_registry -> Module.concat([__MODULE__, "Registry", "Agents"])
          :agent_supervisor -> Module.concat(__MODULE__, :AgentSupervisor)
          :instance_registry -> Module.concat([__MODULE__, "Registry", "Instances"])
          :bridge_registry -> Module.concat([__MODULE__, "Registry", "Bridges"])
          :instance_supervisor -> Module.concat(__MODULE__, :InstanceSupervisor)
          :bridge_supervisor -> Module.concat(__MODULE__, :BridgeSupervisor)
          :onboarding_registry -> Module.concat([__MODULE__, "Registry", "Onboarding"])
          :onboarding_supervisor -> Module.concat(__MODULE__, :OnboardingSupervisor)
          :session_manager_supervisor -> Module.concat(__MODULE__, :SessionManagerSupervisor)
          :dead_letter -> Module.concat(__MODULE__, :DeadLetter)
          :dead_letter_replay_supervisor -> Module.concat(__MODULE__, :DeadLetterReplaySupervisor)
          :config_store -> Module.concat(__MODULE__, :ConfigStore)
          :deduper -> Module.concat(__MODULE__, :Deduper)
          :persistence -> @persistence
          :persistence_opts -> @persistence_opts
          :runtime_profile -> @runtime_profile
          :runtime_features -> @runtime_features
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

      @doc "Create an authorization membership for a canonical principal and room"
      def create_membership(attrs) do
        Jido.Messaging.create_membership(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get an authorization membership by record ID"
      def get_membership(membership_id) do
        Jido.Messaging.get_membership(__jido_messaging__(:runtime), membership_id)
      end

      @doc "List authorization memberships for a room"
      def list_memberships(room_id, opts \\ []) do
        Jido.Messaging.list_memberships(__jido_messaging__(:runtime), room_id, opts)
      end

      @doc "Change membership status with an expected revision"
      def transition_membership(membership_id, expected_revision, status) do
        Jido.Messaging.transition_membership(
          __jido_messaging__(:runtime),
          membership_id,
          expected_revision,
          status
        )
      end

      @doc "Create a durable messaging grant for a canonical principal"
      def create_principal_grant(attrs) do
        Jido.Messaging.create_principal_grant(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a principal messaging grant by record ID"
      def get_principal_grant(grant_id) do
        Jido.Messaging.get_principal_grant(__jido_messaging__(:runtime), grant_id)
      end

      @doc "List durable messaging grants for a principal"
      def list_principal_grants(principal_id, opts \\ []) do
        Jido.Messaging.list_principal_grants(
          __jido_messaging__(:runtime),
          principal_id,
          opts
        )
      end

      @doc "Revise a principal grant with an expected revision"
      def revise_principal_grant(grant_id, expected_revision, attrs) do
        Jido.Messaging.revise_principal_grant(
          __jido_messaging__(:runtime),
          grant_id,
          expected_revision,
          attrs
        )
      end

      @doc "Revoke a principal grant with an expected revision"
      def revoke_principal_grant(grant_id, expected_revision) do
        Jido.Messaging.revoke_principal_grant(
          __jido_messaging__(:runtime),
          grant_id,
          expected_revision
        )
      end

      @doc "Create a messaging invocation policy for an agent principal"
      def create_invocation_policy(attrs) do
        Jido.Messaging.create_invocation_policy(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get an invocation policy by record ID"
      def get_invocation_policy(policy_id) do
        Jido.Messaging.get_invocation_policy(__jido_messaging__(:runtime), policy_id)
      end

      @doc "List invocation policies for an agent principal"
      def list_invocation_policies(target_principal_id, opts \\ []) do
        Jido.Messaging.list_invocation_policies(
          __jido_messaging__(:runtime),
          target_principal_id,
          opts
        )
      end

      @doc "Revise an invocation policy with an expected revision"
      def revise_invocation_policy(policy_id, expected_revision, attrs) do
        Jido.Messaging.revise_invocation_policy(
          __jido_messaging__(:runtime),
          policy_id,
          expected_revision,
          attrs
        )
      end

      @doc "Revoke an invocation policy with an expected revision"
      def revoke_invocation_policy(policy_id, expected_revision) do
        Jido.Messaging.revoke_invocation_policy(
          __jido_messaging__(:runtime),
          policy_id,
          expected_revision
        )
      end

      @doc "Check current durable messaging authorization for a principal"
      def authorize(principal_id, action, scope) do
        Jido.Messaging.Authorizer.check(
          __jido_messaging__(:runtime),
          principal_id,
          action,
          scope
        )
      end

      @doc "Save a message"
      def save_message(attrs) do
        Jido.Messaging.save_message(__jido_messaging__(:runtime), attrs)
      end

      @doc "Persist a message and emit a committed `jido.messaging.room.message_added` signal"
      def post_message(attrs, opts \\ []) do
        Jido.Messaging.post_message(__MODULE__, __jido_messaging__(:runtime), attrs, opts)
      end

      @doc "Get a message by ID"
      def get_message(message_id) do
        Jido.Messaging.get_message(__jido_messaging__(:runtime), message_id)
      end

      @doc """
      Mark a provider message as read and persist its normalized receipt.

      ## Example

          iex> defmodule ReceiptExample do
          ...>   use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
          ...> end
          iex> function_exported?(ReceiptExample, :mark_message_as_read, 3)
          true
      """
      def mark_message_as_read(message_id, participant_id, opts \\ []) do
        Jido.Messaging.mark_message_as_read(
          __MODULE__,
          __jido_messaging__(:runtime),
          message_id,
          participant_id,
          opts
        )
      end

      @doc """
      List messages for a room.

      Use a message ID with `:before` or `:after` for cursor pagination. The
      two cursor options are mutually exclusive.
      """
      def list_messages(room_id, opts \\ []) do
        Jido.Messaging.list_messages(__jido_messaging__(:runtime), room_id, opts)
      end

      @doc "Return raw timeline/thread grouping for a room"
      def room_timeline(room_id, opts \\ []) do
        Jido.Messaging.room_timeline(__jido_messaging__(:runtime), room_id, opts)
      end

      @doc "Build an instance-bound authorization scope for history queries"
      def history_scope(room_ids, metadata \\ %{}) do
        Jido.Messaging.HistoryScope.new(__MODULE__, room_ids, metadata)
      end

      @doc "Return messages sent by one canonical participant in the allowed history scope"
      def participant_transcript(participant_id, scope, opts \\ []) do
        Jido.Messaging.participant_transcript(
          __MODULE__,
          __jido_messaging__(:runtime),
          participant_id,
          scope,
          opts
        )
      end

      @doc "Search an optional transcript projection within the allowed history scope"
      def search_transcript(query, scope, opts \\ []) do
        Jido.Messaging.search_transcript(__MODULE__, query, scope, opts)
      end

      @doc "Upsert one committed canonical message into the optional search projection"
      def upsert_transcript_search(message_id, scope, opts \\ []) do
        Jido.Messaging.upsert_transcript_search(
          __MODULE__,
          __jido_messaging__(:runtime),
          message_id,
          scope,
          opts
        )
      end

      @doc "Delete one committed canonical message from the optional search projection"
      def delete_transcript_search(message_id, room_id, scope, opts \\ []) do
        Jido.Messaging.delete_transcript_search(__MODULE__, message_id, room_id, scope, opts)
      end

      @doc "Rebuild the optional search projection from canonical participant history"
      def rebuild_transcript_search(participant_id, scope, opts \\ []) do
        Jido.Messaging.rebuild_transcript_search(
          __MODULE__,
          __jido_messaging__(:runtime),
          participant_id,
          scope,
          opts
        )
      end

      @doc "Delete a message"
      def delete_message(message_id) do
        Jido.Messaging.delete_message(__jido_messaging__(:runtime), message_id)
      end

      @doc "Save a thread"
      def save_thread(attrs) do
        Jido.Messaging.save_thread(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a thread by ID"
      def get_thread(thread_id) do
        Jido.Messaging.get_thread(__jido_messaging__(:runtime), thread_id)
      end

      @doc "Get a thread by external thread ID within a room"
      def get_thread_by_external_id(room_id, external_thread_id) do
        Jido.Messaging.get_thread_by_external_id(
          __jido_messaging__(:runtime),
          room_id,
          external_thread_id
        )
      end

      @doc "Get a thread by root message ID"
      def get_thread_by_root_message(room_id, root_message_id) do
        Jido.Messaging.get_thread_by_root_message(
          __jido_messaging__(:runtime),
          room_id,
          root_message_id
        )
      end

      @doc "List threads in a room"
      def list_threads(room_id, opts \\ []) do
        Jido.Messaging.list_threads(__jido_messaging__(:runtime), room_id, opts)
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

      @doc "Get or create a participant by bridge-scoped external identity"
      def get_or_create_participant_by_external_id(channel, bridge_id, external_id, attrs) do
        Jido.Messaging.get_or_create_participant_by_external_id(
          __jido_messaging__(:runtime),
          channel,
          bridge_id,
          external_id,
          attrs
        )
      end

      @doc "Bind a bridge-scoped external identity to an existing participant"
      def bind_participant_external_id(participant_id, channel, bridge_id, external_id) do
        Jido.Messaging.bind_participant_external_id(
          __jido_messaging__(:runtime),
          participant_id,
          channel,
          bridge_id,
          external_id
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

      @doc "Add a reaction to a message and emit a committed reaction signal"
      def add_reaction(message_id, participant_id, reaction, opts \\ []) do
        Jido.Messaging.add_reaction(
          __MODULE__,
          __jido_messaging__(:runtime),
          message_id,
          participant_id,
          reaction,
          opts
        )
      end

      @doc "Remove a reaction from a message and emit a committed reaction signal"
      def remove_reaction(message_id, participant_id, reaction, opts \\ []) do
        Jido.Messaging.remove_reaction(
          __MODULE__,
          __jido_messaging__(:runtime),
          message_id,
          participant_id,
          reaction,
          opts
        )
      end

      @doc "Save an already-constructed thread struct (for updates)"
      def save_thread_struct(thread) do
        Jido.Messaging.save_thread_struct(__jido_messaging__(:runtime), thread)
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

      @doc "Register an agent with a room"
      def register_agent(room_id, agent_spec, opts \\ []) do
        Jido.Messaging.register_agent(__MODULE__, room_id, agent_spec, opts)
      end

      @doc "Unregister an agent from a room"
      def unregister_agent(room_id, agent_id) do
        Jido.Messaging.unregister_agent(__MODULE__, room_id, agent_id)
      end

      @doc "List registered agents in a room"
      def list_agents(room_id) do
        Jido.Messaging.list_agents(__MODULE__, room_id)
      end

      @doc "Assign a thread to an agent"
      def assign_thread(room_id, thread_id, agent_id) do
        Jido.Messaging.assign_thread(__MODULE__, room_id, thread_id, agent_id)
      end

      @doc "Unassign a thread"
      def unassign_thread(room_id, thread_id) do
        Jido.Messaging.unassign_thread(__MODULE__, room_id, thread_id)
      end

      @doc "Fetch thread assignment"
      def thread_assignment(room_id, thread_id) do
        Jido.Messaging.thread_assignment(__MODULE__, room_id, thread_id)
      end

      @doc "Find a running agent by room, thread, and agent ID"
      def whereis_agent(room_id, thread_id, agent_id) do
        Jido.Messaging.AgentRunner.whereis(__MODULE__, room_id, thread_id, agent_id)
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

      @doc "Get runtime status for a bridge worker."
      def bridge_status(bridge_id) do
        Jido.Messaging.bridge_status(__MODULE__, bridge_id)
      end

      @doc "List runtime status for all bridge workers."
      def list_bridge_status do
        Jido.Messaging.list_bridge_status(__MODULE__)
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

      @doc "Ensure adapter-scoped provider ingress subscription for a bridge."
      def ensure_ingress_subscription(bridge_id, opts \\ []) do
        Jido.Messaging.ensure_ingress_subscription(__MODULE__, bridge_id, opts)
      end

      @doc "List adapter-scoped provider ingress subscriptions for a bridge."
      def list_ingress_subscriptions(bridge_id, opts \\ []) do
        Jido.Messaging.list_ingress_subscriptions(__MODULE__, bridge_id, opts)
      end

      @doc "Delete adapter-scoped provider ingress subscription for a bridge."
      def delete_ingress_subscription(bridge_id, subscription_id, opts \\ []) do
        Jido.Messaging.delete_ingress_subscription(__MODULE__, bridge_id, subscription_id, opts)
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

      @doc "Route webhook request and return typed webhook response + ingest outcome."
      def route_webhook_request(bridge_id, request_meta, payload, opts \\ []) do
        Jido.Messaging.route_webhook_request(__MODULE__, bridge_id, request_meta, payload, opts)
      end

      @doc "Route direct payload through bridge-config transform path into ingest."
      def route_payload(bridge_id, payload, opts \\ []) do
        Jido.Messaging.route_payload(__MODULE__, bridge_id, payload, opts)
      end

      @doc "Create or ensure a bridge-backed room topology in one call."
      def create_bridge_room(attrs) do
        Jido.Messaging.create_bridge_room(__MODULE__, attrs)
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

      @doc "Subscribe to Jido Signal events emitted by this messaging instance"
      def subscribe_signals(path \\ "jido.messaging.**", opts \\ []) do
        Jido.Messaging.subscribe_signals(__MODULE__, path, opts)
      end

      @doc "Unsubscribe from a Jido Signal Bus subscription"
      def unsubscribe_signals(subscription_id, opts \\ []) do
        Jido.Messaging.unsubscribe_signals(__MODULE__, subscription_id, opts)
      end

      @doc "Emit a custom room-scoped Jido Signal event"
      def dispatch_room_event(event_type, room_id, data \\ %{}, opts \\ []) do
        Jido.Messaging.dispatch_room_event(__MODULE__, event_type, room_id, data, opts)
      end

      @doc "Emit a room-scoped participant joined signal"
      def participant_joined(room_id, participant_id, opts \\ []) do
        Jido.Messaging.participant_joined(__MODULE__, room_id, participant_id, opts)
      end

      @doc "Emit a room-scoped participant left signal"
      def participant_left(room_id, participant_id, opts \\ []) do
        Jido.Messaging.participant_left(__MODULE__, room_id, participant_id, opts)
      end

      @doc "Emit a participant presence changed signal"
      def participant_presence_changed(room_id, participant_id, from, to, opts \\ []) do
        Jido.Messaging.participant_presence_changed(__MODULE__, room_id, participant_id, from, to, opts)
      end

      @doc "Emit a participant typing signal"
      def participant_typing(room_id, participant_id, is_typing, opts \\ []) do
        Jido.Messaging.participant_typing(__MODULE__, room_id, participant_id, is_typing, opts)
      end

      @doc "Return the instance Signal Bus name"
      def signal_bus_name do
        Jido.Messaging.Supervisor.signal_bus_name(__MODULE__)
      end
    end
  end

  # Core API implementations that work with the Runtime

  @doc "Create a new room"
  def create_room(runtime, attrs) when is_map(attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    room = Room.new(attrs)
    persistence.save_room(persistence_state, room)
  end

  @doc "Get a room by ID"
  def get_room(runtime, room_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_room(persistence_state, room_id)
  end

  @doc "Save a room struct directly (for custom IDs)"
  def save_room(runtime, %Room{} = room) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.save_room(persistence_state, room)
  end

  @doc "List rooms"
  def list_rooms(runtime, opts \\ []) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.list_rooms(persistence_state, opts)
  end

  @doc "Delete a room"
  def delete_room(runtime, room_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.delete_room(persistence_state, room_id)
  end

  @doc "Create a new participant"
  def create_participant(runtime, attrs) when is_map(attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    participant = Participant.new(attrs)
    persistence.save_participant(persistence_state, participant)
  end

  @doc "Get a participant by ID"
  def get_participant(runtime, participant_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_participant(persistence_state, participant_id)
  end

  @doc "Create an authorization membership for a canonical principal and room."
  def create_membership(runtime, attrs) when is_map(attrs),
    do: AccessControl.create_membership(runtime, attrs)

  @doc "Get an authorization membership by record ID."
  def get_membership(runtime, membership_id) when is_binary(membership_id),
    do: AccessControl.get_membership(runtime, membership_id)

  @doc "List authorization memberships for a room."
  def list_memberships(runtime, room_id, opts \\ [])
      when is_binary(room_id) and is_list(opts),
      do: AccessControl.list_memberships(runtime, room_id, opts)

  @doc "Change membership status with an expected revision."
  def transition_membership(runtime, membership_id, expected_revision, status)
      when is_binary(membership_id) and is_integer(expected_revision),
      do: AccessControl.transition_membership(runtime, membership_id, expected_revision, status)

  @doc "Create a durable messaging grant for a canonical principal."
  def create_principal_grant(runtime, attrs) when is_map(attrs),
    do: AccessControl.create_grant(runtime, attrs)

  @doc "Get a principal messaging grant by record ID."
  def get_principal_grant(runtime, grant_id) when is_binary(grant_id),
    do: AccessControl.get_grant(runtime, grant_id)

  @doc "List durable messaging grants for a principal."
  def list_principal_grants(runtime, principal_id, opts \\ [])
      when is_binary(principal_id) and is_list(opts),
      do: AccessControl.list_grants(runtime, principal_id, opts)

  @doc "Revise a principal grant with an expected revision."
  def revise_principal_grant(runtime, grant_id, expected_revision, attrs)
      when is_binary(grant_id) and is_integer(expected_revision) and is_map(attrs),
      do: AccessControl.revise_grant(runtime, grant_id, expected_revision, attrs)

  @doc "Revoke a principal grant with an expected revision."
  def revoke_principal_grant(runtime, grant_id, expected_revision)
      when is_binary(grant_id) and is_integer(expected_revision),
      do: AccessControl.revoke_grant(runtime, grant_id, expected_revision)

  @doc "Create a messaging invocation policy for an agent principal."
  def create_invocation_policy(runtime, attrs) when is_map(attrs),
    do: AccessControl.create_invocation_policy(runtime, attrs)

  @doc "Get an invocation policy by record ID."
  def get_invocation_policy(runtime, policy_id) when is_binary(policy_id),
    do: AccessControl.get_invocation_policy(runtime, policy_id)

  @doc "List invocation policies for an agent principal."
  def list_invocation_policies(runtime, target_principal_id, opts \\ [])
      when is_binary(target_principal_id) and is_list(opts),
      do: AccessControl.list_invocation_policies(runtime, target_principal_id, opts)

  @doc "Revise an invocation policy with an expected revision."
  def revise_invocation_policy(runtime, policy_id, expected_revision, attrs)
      when is_binary(policy_id) and is_integer(expected_revision) and is_map(attrs),
      do: AccessControl.revise_invocation_policy(runtime, policy_id, expected_revision, attrs)

  @doc "Revoke an invocation policy with an expected revision."
  def revoke_invocation_policy(runtime, policy_id, expected_revision)
      when is_binary(policy_id) and is_integer(expected_revision),
      do: AccessControl.revoke_invocation_policy(runtime, policy_id, expected_revision)

  @doc "Save a message"
  def save_message(runtime, attrs) when is_map(attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    message = Message.new(attrs)
    persistence.save_message(persistence_state, message)
  end

  @doc """
  Persist a message and emit the committed `jido.messaging.room.message_added` signal.

  This is the eventful command API for chat apps. `save_message/2` remains the
  low-level persistence primitive for migrations, imports, and tests that need
  no side effects.
  """
  def post_message(instance_module, runtime, attrs, opts \\ [])
      when is_atom(instance_module) and is_map(attrs) do
    opts = normalize_event_opts(opts)

    with {:ok, message} <- save_message(runtime, attrs),
         {:ok, signal} <- Jido.Messaging.Events.message_added(instance_module, message, signal_opts(message, opts)),
         {:ok, signal} <-
           Jido.Messaging.Dispatch.emit(instance_module, signal,
             telemetry_event: Jido.Messaging.Events.telemetry_event_for(:message_added),
             telemetry_metadata:
               telemetry_metadata(instance_module, :message_added, message.room_id, %{
                 message: message,
                 sender_id: message.sender_id,
                 thread_id: message.thread_id
               }),
             room_id: message.room_id,
             legacy_event: {:message_added, message}
           ) do
      {:ok, Jido.Messaging.CommandResult.new(message, [signal])}
    end
  end

  @doc "Get a message by ID"
  def get_message(runtime, message_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_message(persistence_state, message_id)
  end

  @doc "Mark a provider message as read and persist its normalized receipt."
  def mark_message_as_read(instance_module, runtime, message_id, participant_id, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(participant_id) and
             is_list(opts) do
    Jido.Messaging.ReadReceipt.mark_as_read(
      instance_module,
      runtime,
      message_id,
      participant_id,
      opts
    )
  end

  @doc """
  List messages for a room.

  Use a message ID with `:before` or `:after` for cursor pagination. The two
  cursor options are mutually exclusive.
  """
  def list_messages(runtime, room_id, opts \\ []) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_messages(persistence_state, room_id, opts)
  end

  @doc """
  Return raw timeline and thread grouping for a room.

  This helper returns canonical message structs grouped into top-level
  timeline messages, thread replies, and reply counts. Apps still own their
  user-facing chat context and UI projections.
  """
  def room_timeline(runtime, room_id, opts \\ []) do
    with {:ok, messages} <- list_messages(runtime, room_id, opts) do
      {:ok, Jido.Messaging.Query.room_timeline(messages)}
    end
  end

  @doc """
  Return participant-scoped canonical history within an explicit room scope.

  The scope must belong to `instance_module`. The persistence query receives
  only the allowed room IDs, so cursors from other rooms return
  `{:error, :cursor_not_found}`.
  """
  def participant_transcript(instance_module, runtime, participant_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(participant_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {persistence, persistence_state} <- Runtime.get_persistence(runtime),
         {:ok, participant} <- persistence.get_participant(persistence_state, participant_id),
         {:ok, messages} <-
           persistence.get_participant_messages(persistence_state, participant_id, scope.room_ids, opts) do
      {:ok, Enum.map(messages, &Jido.Messaging.TranscriptEntry.new(instance_module, participant, &1))}
    end
  end

  @doc "Search a configured optional transcript projection."
  def search_transcript(instance_module, query, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(query) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection) do
      context = %{instance_module: instance_module, scope: scope}

      with {:ok, entries} <- projection.search(query, context, Keyword.delete(opts, :projection)),
           :ok <- validate_projection_results(entries, instance_module, scope) do
        {:ok, entries}
      end
    end
  end

  @doc "Upsert one committed canonical message into a configured search projection."
  def upsert_transcript_search(instance_module, runtime, message_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection),
         {persistence, persistence_state} <- Runtime.get_persistence(runtime),
         {:ok, message} <- persistence.get_message(persistence_state, message_id),
         :ok <- validate_history_room(scope, message.room_id),
         {:ok, participant} <- persistence.get_participant(persistence_state, message.sender_id) do
      entry = Jido.Messaging.TranscriptEntry.new(instance_module, participant, message)
      context = %{instance_module: instance_module, scope: scope}
      projection.upsert(entry, context, Keyword.delete(opts, :projection))
    end
  end

  @doc "Delete one committed canonical message from a configured search projection."
  def delete_transcript_search(instance_module, message_id, room_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(room_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         :ok <- validate_history_room(scope, room_id),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection) do
      context = %{instance_module: instance_module, scope: scope}
      projection.delete(message_id, context, Keyword.delete(opts, :projection))
    end
  end

  @doc "Rebuild a configured search projection from canonical participant history."
  def rebuild_transcript_search(instance_module, runtime, participant_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(participant_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection),
         {:ok, entries} <- collect_transcript(instance_module, runtime, participant_id, scope, opts) do
      context = %{instance_module: instance_module, scope: scope}
      projection.rebuild(entries, context, Keyword.drop(opts, [:projection, :batch_size]))
    end
  end

  @doc "Delete a message"
  def delete_message(runtime, message_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.delete_message(persistence_state, message_id)
  end

  @doc "Get or create room by external binding"
  def get_or_create_room_by_external_binding(runtime, channel, bridge_id, external_id, attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    persistence.get_or_create_room_by_external_binding(
      persistence_state,
      channel,
      bridge_id,
      external_id,
      attrs
    )
  end

  @doc "Get or create participant by external ID"
  def get_or_create_participant_by_external_id(runtime, channel, external_id, attrs) do
    get_or_create_participant_by_external_id(runtime, channel, "default", external_id, attrs)
  end

  @doc "Get or create a participant by bridge-scoped external identity"
  def get_or_create_participant_by_external_id(runtime, channel, bridge_id, external_id, attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    if function_exported?(persistence, :get_or_create_participant_by_external_binding, 5) do
      persistence.get_or_create_participant_by_external_binding(
        persistence_state,
        channel,
        bridge_id,
        external_id,
        attrs
      )
    else
      persistence.get_or_create_participant_by_external_id(persistence_state, channel, external_id, attrs)
    end
  end

  @doc "Bind a bridge-scoped external identity to an existing participant"
  def bind_participant_external_id(runtime, participant_id, channel, bridge_id, external_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    if function_exported?(persistence, :bind_participant_external_id, 5) do
      persistence.bind_participant_external_id(
        persistence_state,
        participant_id,
        channel,
        bridge_id,
        external_id
      )
    else
      {:error, :unsupported}
    end
  end

  @doc "Get a message by its external ID within a channel/instance context"
  def get_message_by_external_id(runtime, channel, bridge_id, external_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_message_by_external_id(persistence_state, channel, bridge_id, external_id)
  end

  @doc "Update a message's external_id"
  def update_message_external_id(runtime, message_id, external_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.update_message_external_id(persistence_state, message_id, external_id)
  end

  @doc "Save an already-constructed message struct (for updates)"
  def save_message_struct(runtime, %Message{} = message) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.save_message(persistence_state, message)
  end

  @doc "Add a participant reaction to a message and emit a committed reaction signal."
  def add_reaction(instance_module, runtime, message_id, participant_id, reaction, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(participant_id) and
             is_binary(reaction) do
    update_reaction(
      instance_module,
      runtime,
      message_id,
      participant_id,
      reaction,
      :reaction_added,
      normalize_event_opts(opts)
    )
  end

  @doc "Remove a participant reaction from a message and emit a committed reaction signal."
  def remove_reaction(instance_module, runtime, message_id, participant_id, reaction, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(participant_id) and
             is_binary(reaction) do
    update_reaction(
      instance_module,
      runtime,
      message_id,
      participant_id,
      reaction,
      :reaction_removed,
      normalize_event_opts(opts)
    )
  end

  @doc "Dispatch a custom room-scoped Jido Signal event."
  def dispatch_room_event(instance_module, event_type, room_id, data \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_atom(event_type) and is_binary(room_id) and is_map(data) do
    opts = normalize_event_opts(opts)

    with {:ok, signal} <- Jido.Messaging.Events.room_event(instance_module, event_type, room_id, data, opts),
         {:ok, signal} <-
           Jido.Messaging.Dispatch.emit(instance_module, signal,
             telemetry_event: Jido.Messaging.Events.telemetry_event_for(event_type),
             telemetry_metadata: telemetry_metadata(instance_module, event_type, room_id, data),
             room_id: room_id,
             legacy_event: Keyword.get(opts, :legacy_event)
           ) do
      {:ok, signal}
    end
  end

  @doc """
  Emit a canonical participant joined signal for a room.

  This is a transport-agnostic helper for apps that receive participant lifecycle
  information from Phoenix Presence, adapters, polling, or any other source.
  """
  def participant_joined(instance_module, room_id, participant_id, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_binary(participant_id) do
    opts = normalize_event_opts(opts)

    dispatch_room_event(
      instance_module,
      :participant_joined,
      room_id,
      participant_event_data(participant_id, opts),
      opts
    )
  end

  @doc """
  Emit a canonical participant left signal for a room.
  """
  def participant_left(instance_module, room_id, participant_id, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_binary(participant_id) do
    opts = normalize_event_opts(opts)

    dispatch_room_event(
      instance_module,
      :participant_left,
      room_id,
      participant_event_data(participant_id, opts),
      opts
    )
  end

  @doc """
  Emit a canonical participant presence changed signal.
  """
  def participant_presence_changed(instance_module, room_id, participant_id, from, to, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_binary(participant_id) do
    opts = normalize_event_opts(opts)

    data =
      participant_event_data(participant_id, opts)
      |> Map.put(:from, from)
      |> Map.put(:to, to)

    dispatch_room_event(instance_module, :presence_changed, room_id, data, opts)
  end

  @doc """
  Emit a canonical participant typing signal.
  """
  def participant_typing(instance_module, room_id, participant_id, is_typing, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_binary(participant_id) and
             is_boolean(is_typing) do
    opts = normalize_event_opts(opts)

    data =
      participant_event_data(participant_id, opts)
      |> Map.put(:is_typing, is_typing)
      |> maybe_put_data(:thread_id, Keyword.get(opts, :thread_id))

    dispatch_room_event(instance_module, :typing, room_id, data, opts)
  end

  @doc "Subscribe to Jido Signal events for an instance module."
  def subscribe_signals(instance_module, path \\ "jido.messaging.**", opts \\ [])
      when is_atom(instance_module) and is_binary(path) and is_list(opts) do
    Jido.Messaging.Dispatch.subscribe(instance_module, path, opts)
  end

  @doc "Unsubscribe from a Jido Signal Bus subscription."
  def unsubscribe_signals(instance_module, subscription_id, opts \\ [])
      when is_atom(instance_module) and is_list(opts) do
    Jido.Messaging.Dispatch.unsubscribe(instance_module, subscription_id, opts)
  end

  @doc "Save a thread"
  def save_thread(runtime, attrs) when is_map(attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    thread = Thread.new(attrs)
    persistence.save_thread(persistence_state, thread)
  end

  @doc "Save an already-constructed thread struct (for updates)"
  def save_thread_struct(runtime, %Thread{} = thread) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.save_thread(persistence_state, thread)
  end

  @doc "Get a thread by ID"
  def get_thread(runtime, thread_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_thread(persistence_state, thread_id)
  end

  @doc "Get a thread by external thread ID"
  def get_thread_by_external_id(runtime, room_id, external_thread_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_thread_by_external_id(persistence_state, room_id, external_thread_id)
  end

  @doc "Get a thread by root message ID"
  def get_thread_by_root_message(runtime, room_id, root_message_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_thread_by_root_message(persistence_state, room_id, root_message_id)
  end

  @doc "List threads for a room"
  def list_threads(runtime, room_id, opts \\ []) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.list_threads(persistence_state, room_id, opts)
  end

  @doc "Get room by external binding (without creating)"
  def get_room_by_external_binding(runtime, channel, bridge_id, external_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_room_by_external_binding(persistence_state, channel, bridge_id, external_id)
  end

  @doc "Create a binding between an internal room and an external platform"
  def create_room_binding(runtime, room_id, channel, bridge_id, external_id, attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.create_room_binding(persistence_state, room_id, channel, bridge_id, external_id, attrs)
  end

  @doc "List all bindings for a room"
  def list_room_bindings(runtime, room_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.list_room_bindings(persistence_state, room_id)
  end

  @doc "Delete a room binding"
  def delete_room_binding(runtime, binding_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.delete_room_binding(persistence_state, binding_id)
  end

  @doc "Lookup a single directory entry."
  def directory_lookup(runtime, target, query, opts \\ [])
      when is_atom(target) and is_map(query) and is_list(opts) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.directory_lookup(persistence_state, target, query, opts)
  end

  @doc "Search directory entries."
  def directory_search(runtime, target, query, opts \\ [])
      when is_atom(target) and is_map(query) and is_list(opts) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.directory_search(persistence_state, target, query, opts)
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

  @doc "Fetch runtime status for one bridge worker."
  def bridge_status(instance_module, bridge_id)
      when is_atom(instance_module) and is_binary(bridge_id) do
    case Jido.Messaging.BridgeServer.whereis(instance_module, bridge_id) do
      nil -> {:error, :not_found}
      pid -> Jido.Messaging.BridgeServer.status(pid)
    end
  end

  @doc "List runtime status for all bridge workers."
  def list_bridge_status(instance_module) when is_atom(instance_module) do
    Jido.Messaging.BridgeSupervisor.list_bridges(instance_module)
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

  @doc "Ensure adapter-scoped provider ingress subscription for a bridge."
  def ensure_ingress_subscription(instance_module, bridge_id, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_list(opts) do
    IngressSubscriptions.ensure(instance_module, bridge_id, opts)
  end

  @doc "List adapter-scoped provider ingress subscriptions for a bridge."
  def list_ingress_subscriptions(instance_module, bridge_id, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_list(opts) do
    IngressSubscriptions.list(instance_module, bridge_id, opts)
  end

  @doc "Delete adapter-scoped provider ingress subscription for a bridge."
  def delete_ingress_subscription(instance_module, bridge_id, subscription_id, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_binary(subscription_id) and is_list(opts) do
    IngressSubscriptions.delete(instance_module, bridge_id, subscription_id, opts)
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

  @doc "Register an agent with a room."
  def register_agent(instance_module, room_id, agent_spec, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_map(agent_spec) and is_list(opts) do
    normalized_spec = normalize_agent_spec(agent_spec, opts)

    with {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, registered_spec} <- RoomServer.register_agent(room_server, normalized_spec) do
      restore_agent_assignments(instance_module, room_id, room_server, registered_spec)
      {:ok, registered_spec}
    end
  end

  @doc "Unregister an agent from a room."
  def unregister_agent(instance_module, room_id, agent_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(agent_id) do
    runtime = runtime_name(instance_module)

    with {:ok, room_server} <- ensure_room_server(instance_module, room_id) do
      runtime
      |> assigned_thread_ids_for_agent(room_server, room_id, agent_id)
      |> Enum.reduce_while(:ok, fn thread_id, :ok ->
        with :ok <- stop_thread_runner(instance_module, room_id, thread_id, agent_id),
             _ <- clear_persisted_thread_assignment(runtime, room_id, thread_id),
             :ok <- room_server_unassign_thread(room_server, thread_id) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok -> room_server_unregister_agent(room_server, agent_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "List registered agents for a room."
  def list_agents(instance_module, room_id)
      when is_atom(instance_module) and is_binary(room_id) do
    with {:ok, room_server} <- ensure_room_server(instance_module, room_id) do
      {:ok, RoomServer.list_agents(room_server)}
    end
  end

  @doc "Assign a thread to an agent."
  def assign_thread(instance_module, room_id, thread_id, agent_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(thread_id) and is_binary(agent_id) do
    runtime = runtime_name(instance_module)

    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id),
         {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, agent_spec} <- room_server_get_agent(room_server, agent_id) do
      previous_agent_id = room_server_thread_assignment(room_server, thread_id) || thread.assigned_agent_id

      previous_agent_spec =
        registered_agent_spec(instance_module, room_id, thread_id, room_server, previous_agent_id)

      case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
        pid when is_pid(pid) and previous_agent_id == agent_id ->
          updated_thread = maybe_touch_thread_assignment(thread, agent_id)

          with {:ok, persisted_thread} <- persist_thread_assignment(runtime, updated_thread),
               :ok <- room_server_assign_thread(room_server, thread_id, agent_id) do
            {:ok, persisted_thread}
          else
            {:error, reason} ->
              _ = save_thread_struct(runtime, thread)
              {:error, reason}
          end

        _ ->
          updated_thread = %{thread | assigned_agent_id: agent_id, updated_at: DateTime.utc_now()}

          case stop_thread_runner(instance_module, room_id, thread_id, previous_agent_id) do
            :ok ->
              case assign_thread_state(
                     runtime,
                     room_server,
                     instance_module,
                     room_id,
                     thread_id,
                     agent_id,
                     agent_spec,
                     updated_thread
                   ) do
                {:ok, persisted_thread} ->
                  {:ok, persisted_thread}

                {:error, reason} ->
                  case rollback_thread_assignment(
                         instance_module,
                         runtime,
                         room_server,
                         thread,
                         previous_agent_spec
                       ) do
                    :ok -> {:error, reason}
                    {:error, rollback_reason} -> {:error, {:assignment_failed, reason, rollback_reason}}
                  end
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc "Unassign a thread."
  def unassign_thread(instance_module, room_id, thread_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(thread_id) do
    runtime = runtime_name(instance_module)

    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id),
         {:ok, room_server} <- ensure_room_server(instance_module, room_id) do
      assigned_agent_id = room_server_thread_assignment(room_server, thread_id) || thread.assigned_agent_id

      assigned_agent_spec =
        registered_agent_spec(instance_module, room_id, thread_id, room_server, assigned_agent_id)

      case stop_thread_runner(instance_module, room_id, thread_id, assigned_agent_id) do
        :ok ->
          updated_thread = %{thread | assigned_agent_id: nil, updated_at: DateTime.utc_now()}

          case unassign_thread_state(runtime, room_server, updated_thread) do
            {:ok, persisted_thread} ->
              {:ok, persisted_thread}

            {:error, reason} ->
              case rollback_thread_assignment(
                     instance_module,
                     runtime,
                     room_server,
                     thread,
                     assigned_agent_spec
                   ) do
                :ok -> {:error, reason}
                {:error, rollback_reason} -> {:error, {:unassignment_failed, reason, rollback_reason}}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Fetch thread assignment for a room thread."
  def thread_assignment(instance_module, room_id, thread_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(thread_id) do
    runtime = runtime_name(instance_module)

    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id) do
      {:ok, resolve_thread_assignment(instance_module, room_id, thread_id, thread)}
    end
  end

  @doc "Route webhook payload through bridge-config parse/verify path into ingest."
  def route_webhook(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    Jido.Messaging.InboundRouter.route_webhook(instance_module, bridge_id, payload, opts)
  end

  @doc "Route webhook request and return typed response + ingest outcome."
  def route_webhook_request(instance_module, bridge_id, request_meta, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(request_meta) and is_map(payload) and
             is_list(opts) do
    Jido.Messaging.InboundRouter.route_webhook_request(instance_module, bridge_id, request_meta, payload, opts)
  end

  @doc "Route direct payload through bridge-config transform path into ingest."
  def route_payload(instance_module, bridge_id, payload, opts \\ [])
      when is_atom(instance_module) and is_binary(bridge_id) and is_map(payload) and is_list(opts) do
    Jido.Messaging.InboundRouter.route_payload(instance_module, bridge_id, payload, opts)
  end

  @doc false
  def restore_agent_runners(instance_module) when is_atom(instance_module) do
    runtime = runtime_name(instance_module)
    room_supervisor = Module.concat(instance_module, :RoomSupervisor)

    if is_nil(Process.whereis(runtime)) or is_nil(Process.whereis(room_supervisor)) do
      {:error, :runtime_unavailable}
    else
      RoomSupervisor.list_rooms(instance_module)
      |> Enum.each(fn {room_id, room_server} ->
        agent_specs =
          room_server
          |> room_server_list_agents()
          |> case do
            {:ok, agents} -> Map.new(agents, &{&1.agent_id, &1})
            {:error, _reason} -> %{}
          end

        case list_threads(runtime, room_id) do
          {:ok, threads} ->
            Enum.each(threads, fn
              %Thread{id: thread_id, assigned_agent_id: agent_id}
              when is_binary(agent_id) and map_size(agent_specs) > 0 ->
                case Map.fetch(agent_specs, agent_id) do
                  {:ok, agent_spec} ->
                    _ = ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec)
                    :ok

                  :error ->
                    :ok
                end

              _thread ->
                :ok
            end)

          {:error, _reason} ->
            :ok
        end
      end)

      :ok
    end
  end

  @doc false
  def restore_room_server_state(instance_module, room_id, room_server)
      when is_atom(instance_module) and is_binary(room_id) and is_pid(room_server) do
    instance_module
    |> AgentSupervisor.list_agents(room_id)
    |> Enum.each(fn {{thread_id, agent_id}, pid} ->
      case runner_agent_spec(pid, agent_id) do
        {:ok, agent_spec} ->
          _ = room_server_register_agent(room_server, agent_spec)
          _ = room_server_assign_thread(room_server, thread_id, agent_id)
          :ok

        {:error, _reason} ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Create or ensure a bridge-backed room topology in one idempotent call.

  This helper ensures:
    * optional bridge configs are upserted
    * room exists
    * bridge-scoped room bindings exist
    * optional routing policy exists
  """
  def create_bridge_room(instance_module, attrs)
      when is_atom(instance_module) and is_map(attrs) do
    spec = BridgeRoomSpec.new(attrs)
    room_id = spec.room_id || "bridge:" <> Jido.Chat.ID.generate!()
    runtime = runtime_name(instance_module)

    with :ok <- TopologyValidator.validate_bridge_room_spec(instance_module, spec),
         :ok <- ensure_bridge_configs(instance_module, spec.bridge_configs),
         {:ok, room} <- ensure_room(runtime, room_id, spec),
         {:ok, _bindings} <- ensure_bindings(runtime, instance_module, room_id, spec.bindings),
         {:ok, _policy} <- ensure_routing_policy(instance_module, room_id, spec.routing_policy) do
      {:ok, room}
    end
  end

  defp update_reaction(instance_module, runtime, message_id, participant_id, reaction, event_type, opts) do
    with {:ok, message} <- get_message(runtime, message_id) do
      existing_reactions = message.reactions || %{}
      current_participants = existing_reactions |> Map.get(reaction, []) |> List.wrap() |> Enum.map(&to_string/1)

      participants =
        case event_type do
          :reaction_added -> [participant_id | current_participants] |> Enum.uniq() |> Enum.sort()
          :reaction_removed -> Enum.reject(current_participants, &(&1 == participant_id))
        end

      reactions =
        if participants == [] do
          Map.delete(existing_reactions, reaction)
        else
          Map.put(existing_reactions, reaction, participants)
        end

      if reactions == existing_reactions do
        {:ok, Jido.Messaging.CommandResult.new(message, [])}
      else
        updated_message = %{message | reactions: reactions, updated_at: DateTime.utc_now()}

        with {:ok, updated_message} <- save_message_struct(runtime, updated_message),
             {:ok, signal} <-
               reaction_signal(event_type, instance_module, updated_message, participant_id, reaction, opts),
             {:ok, signal} <-
               Jido.Messaging.Dispatch.emit(instance_module, signal,
                 telemetry_event: Jido.Messaging.Events.telemetry_event_for(event_type),
                 telemetry_metadata:
                   telemetry_metadata(instance_module, event_type, updated_message.room_id, %{
                     message_id: updated_message.id,
                     participant_id: participant_id,
                     reaction: reaction,
                     message: updated_message
                   }),
                 room_id: updated_message.room_id,
                 legacy_event:
                   {event_type,
                    %{
                      message_id: updated_message.id,
                      participant_id: participant_id,
                      reaction: reaction,
                      message: updated_message
                    }}
               ) do
          {:ok, Jido.Messaging.CommandResult.new(updated_message, [signal])}
        end
      end
    end
  end

  defp reaction_signal(:reaction_added, instance_module, message, participant_id, reaction, opts) do
    Jido.Messaging.Events.reaction_added(instance_module, message, participant_id, reaction, signal_opts(message, opts))
  end

  defp reaction_signal(:reaction_removed, instance_module, message, participant_id, reaction, opts) do
    Jido.Messaging.Events.reaction_removed(
      instance_module,
      message,
      participant_id,
      reaction,
      signal_opts(message, opts)
    )
  end

  defp signal_opts(%Message{} = message, opts) do
    opts
    |> Keyword.put_new(:message_id, message.id)
    |> Keyword.put_new(:correlation_id, message.id)
    |> Keyword.put_new(:external_message_id, message.external_id)
    |> Keyword.put_new(:external_thread_id, message.external_thread_id)
    |> Keyword.put_new(:delivery_external_room_id, message.delivery_external_room_id)
  end

  defp normalize_event_opts(opts), do: Jido.Messaging.EventOptions.normalize(opts, :command)

  defp telemetry_metadata(instance_module, event_type, room_id, data) do
    data
    |> Map.merge(%{
      room_id: room_id,
      instance_module: instance_module,
      timestamp: DateTime.utc_now(),
      correlation_id:
        data[:message_id] || data["message_id"] || data[:participant_id] || data["participant_id"] ||
          "corr_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    })
    |> Map.put_new(:event_type, event_type)
  end

  defp participant_event_data(participant_id, opts) do
    %{
      participant_id: participant_id,
      session_id: Keyword.get(opts, :session_id),
      presence: Keyword.get(opts, :presence),
      source: Keyword.get(opts, :source)
    }
    |> maybe_put_data(:metadata, Keyword.get(opts, :metadata))
    |> maybe_put_data(:reason, Keyword.get(opts, :reason))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_put_data(data, _key, nil), do: data
  defp maybe_put_data(data, key, value), do: Map.put(data, key, value)

  defp ensure_bridge_configs(_instance_module, []), do: :ok

  defp ensure_bridge_configs(instance_module, bridge_configs) when is_list(bridge_configs) do
    Enum.reduce_while(bridge_configs, :ok, fn config, :ok ->
      attrs = normalize_bridge_config_attrs(config)

      case put_bridge_config(instance_module, attrs) do
        {:ok, _bridge} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:bridge_config_failed, reason, config}}}
      end
    end)
  end

  defp ensure_room(runtime, room_id, %BridgeRoomSpec{} = spec) do
    case get_room(runtime, room_id) do
      {:ok, room} ->
        {:ok, room}

      {:error, :not_found} ->
        save_room(
          runtime,
          Room.new(%{
            id: room_id,
            type: spec.room_type,
            name: spec.room_name,
            metadata: spec.room_metadata
          })
        )

      {:error, reason} ->
        {:error, {:room_lookup_failed, reason}}
    end
  end

  defp ensure_bindings(_runtime, _instance_module, _room_id, []), do: {:ok, []}

  defp ensure_bindings(runtime, instance_module, room_id, bindings) when is_list(bindings) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, acc} ->
      with {:ok, normalized} <- normalize_binding(binding),
           {:ok, _bridge} <- ensure_binding_bridge_enabled(instance_module, normalized.bridge_id),
           {:ok, result} <- ensure_binding(runtime, room_id, normalized) do
        {:cont, {:ok, [result | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_binding(runtime, room_id, normalized) do
    case get_room_by_external_binding(
           runtime,
           normalized.channel,
           normalized.bridge_id,
           normalized.external_room_id
         ) do
      {:ok, %Room{id: ^room_id}} ->
        {:ok, :existing}

      {:ok, %Room{id: existing_room_id}} ->
        {:error,
         {:binding_conflict,
          %{
            room_id: room_id,
            existing_room_id: existing_room_id,
            channel: normalized.channel,
            bridge_id: normalized.bridge_id,
            external_room_id: normalized.external_room_id
          }}}

      {:error, :not_found} ->
        create_room_binding(
          runtime,
          room_id,
          normalized.channel,
          normalized.bridge_id,
          normalized.external_room_id,
          normalized.attrs
        )

      {:error, reason} ->
        {:error, {:binding_lookup_failed, reason}}
    end
  end

  defp ensure_binding_bridge_enabled(instance_module, bridge_id) when is_binary(bridge_id) do
    case get_bridge_config(instance_module, bridge_id) do
      {:ok, %{enabled: true} = config} -> {:ok, config}
      {:ok, %{enabled: false}} -> {:error, {:bridge_disabled, bridge_id}}
      {:error, :not_found} -> {:error, {:bridge_not_found, bridge_id}}
    end
  end

  defp ensure_routing_policy(_instance_module, _room_id, policy) when policy in [%{}, nil], do: {:ok, nil}

  defp ensure_routing_policy(instance_module, room_id, policy) when is_map(policy) do
    attrs = Map.put(policy, :room_id, room_id)

    case put_routing_policy(instance_module, room_id, attrs) do
      {:ok, routing_policy} -> {:ok, routing_policy}
      {:error, reason} -> {:error, {:routing_policy_failed, reason}}
    end
  end

  defp normalize_bridge_config_attrs(config) when is_map(config) do
    normalized =
      Enum.reduce(config, %{}, fn
        {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
        {key, value}, acc when is_binary(key) -> put_bridge_config_string_key(acc, key, value)
        {_key, _value}, acc -> acc
      end)

    normalized
    |> Map.put_new(:enabled, true)
    |> Map.put_new(:opts, %{})
    |> Map.put_new(:credentials, %{})
  end

  defp put_bridge_config_string_key(acc, key, value) when is_map(acc) and is_binary(key) do
    case bridge_config_key_to_atom(key) do
      nil -> Map.put(acc, key, value)
      atom_key -> Map.put(acc, atom_key, value)
    end
  end

  defp bridge_config_key_to_atom("id"), do: :id
  defp bridge_config_key_to_atom("adapter_module"), do: :adapter_module
  defp bridge_config_key_to_atom("adapter"), do: :adapter_module
  defp bridge_config_key_to_atom("credentials"), do: :credentials
  defp bridge_config_key_to_atom("opts"), do: :opts
  defp bridge_config_key_to_atom("enabled"), do: :enabled
  defp bridge_config_key_to_atom("capabilities"), do: :capabilities
  defp bridge_config_key_to_atom("delivery_policy"), do: :delivery_policy
  defp bridge_config_key_to_atom("revision"), do: :revision
  defp bridge_config_key_to_atom("inserted_at"), do: :inserted_at
  defp bridge_config_key_to_atom("updated_at"), do: :updated_at
  defp bridge_config_key_to_atom(_), do: nil

  defp normalize_binding(binding) when is_map(binding) do
    channel = map_get(binding, :channel) |> normalize_channel()
    bridge_id = map_get(binding, :bridge_id) |> normalize_id()
    external_room_id = map_get(binding, :external_room_id) |> normalize_id()
    direction = map_get(binding, :direction) |> normalize_direction()
    enabled = map_get(binding, :enabled) |> normalize_bool()

    with true <- is_atom(channel),
         true <- is_binary(bridge_id),
         true <- is_binary(external_room_id) do
      attrs =
        binding
        |> drop_keys([
          :channel,
          "channel",
          :bridge_id,
          "bridge_id",
          :external_room_id,
          "external_room_id",
          :direction,
          "direction",
          :enabled,
          "enabled"
        ])
        |> put_attr(:direction, direction)
        |> put_attr(:enabled, enabled)

      {:ok,
       %{
         channel: channel,
         bridge_id: bridge_id,
         external_room_id: external_room_id,
         attrs: attrs
       }}
    else
      _ -> {:error, {:invalid_binding, binding}}
    end
  end

  defp map_get(map, atom_key) when is_map(map) and is_atom(atom_key),
    do: Map.get(map, atom_key, Map.get(map, Atom.to_string(atom_key)))

  defp drop_keys(map, keys), do: Enum.reduce(keys, map, &Map.delete(&2, &1))

  defp put_attr(attrs, key, value) when is_map(attrs), do: Map.put(attrs, key, value)

  defp normalize_channel(:telegram), do: :telegram
  defp normalize_channel(:discord), do: :discord
  defp normalize_channel("telegram"), do: :telegram
  defp normalize_channel("discord"), do: :discord
  defp normalize_channel(_), do: nil

  defp normalize_direction(:inbound), do: :inbound
  defp normalize_direction(:outbound), do: :outbound
  defp normalize_direction("inbound"), do: :inbound
  defp normalize_direction("outbound"), do: :outbound
  defp normalize_direction(_), do: :both

  defp normalize_bool(true), do: true
  defp normalize_bool(false), do: false
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool("1"), do: true
  defp normalize_bool("0"), do: false
  defp normalize_bool(1), do: true
  defp normalize_bool(0), do: false
  defp normalize_bool(_), do: true

  defp normalize_id(value) when is_binary(value) and value != "", do: value
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_id(_), do: nil

  defp normalize_agent_spec(agent_spec, opts) when is_map(agent_spec) and is_list(opts) do
    agent_id =
      map_get(agent_spec, :agent_id) ||
        map_get(agent_spec, :id) ||
        raise ArgumentError, "agent_spec requires :agent_id"

    name = map_get(agent_spec, :name) || agent_id

    mention_handles =
      agent_spec
      |> map_get(:mention_handles)
      |> case do
        handles when is_list(handles) -> handles
        _ -> [agent_id, name]
      end
      |> Enum.map(&normalize_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    agent_spec
    |> Map.put(:agent_id, normalize_id(agent_id))
    |> Map.put(:name, normalize_id(name) || to_string(name))
    |> Map.put(:mention_handles, mention_handles)
    |> Map.put_new(:trigger, Keyword.get(opts, :trigger, :thread))
  end

  defp restore_agent_assignments(instance_module, room_id, room_server, agent_spec) do
    runtime = runtime_name(instance_module)
    agent_id = agent_spec.agent_id

    with {:ok, threads} <- list_threads(runtime, room_id) do
      Enum.each(threads, fn
        %Thread{id: thread_id, assigned_agent_id: ^agent_id} ->
          case room_server_thread_assignment(room_server, thread_id) do
            nil ->
              _ = room_server_assign_thread(room_server, thread_id, agent_id)
              _ = ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec)

            ^agent_id ->
              _ = ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec)

            _other ->
              :ok
          end

        _thread ->
          :ok
      end)
    end

    :ok
  end

  defp assigned_thread_ids_for_agent(runtime, room_server, room_id, agent_id) do
    in_memory_thread_ids =
      case room_server_list_thread_assignments(room_server) do
        {:ok, assignments} ->
          Enum.flat_map(assignments, fn
            {thread_id, ^agent_id} -> [thread_id]
            {_thread_id, _assigned_agent_id} -> []
          end)

        {:error, _reason} ->
          []
      end

    persisted_thread_ids =
      case list_threads(runtime, room_id) do
        {:ok, threads} ->
          Enum.flat_map(threads, fn
            %Thread{id: thread_id, assigned_agent_id: ^agent_id} -> [thread_id]
            _thread -> []
          end)

        {:error, _reason} ->
          []
      end

    Enum.uniq(in_memory_thread_ids ++ persisted_thread_ids)
  end

  defp ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
    case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec)
    end
  end

  defp clear_persisted_thread_assignment(runtime, room_id, thread_id) do
    with {:ok, thread} <- get_thread(runtime, thread_id),
         :ok <- ensure_thread_room(thread, room_id) do
      updated_thread = %{thread | assigned_agent_id: nil, updated_at: DateTime.utc_now()}
      save_thread_struct(runtime, updated_thread)
    else
      _ -> :ok
    end
  end

  defp persist_thread_assignment(runtime, %Thread{} = thread) do
    save_thread_struct(runtime, thread)
  end

  defp resolve_thread_assignment(instance_module, room_id, thread_id, %Thread{} = thread) do
    case ensure_room_server(instance_module, room_id) do
      {:ok, room_server} ->
        case room_server_thread_assignment_result(room_server, thread_id) do
          {:ok, assignment} -> assignment || thread.assigned_agent_id
          {:error, _reason} -> thread.assigned_agent_id
        end

      {:error, _reason} ->
        thread.assigned_agent_id
    end
  end

  defp assign_thread_state(
         runtime,
         room_server,
         instance_module,
         room_id,
         thread_id,
         agent_id,
         agent_spec,
         updated_thread
       ) do
    with {:ok, persisted_thread} <- persist_thread_assignment(runtime, updated_thread),
         :ok <- room_server_assign_thread(room_server, thread_id, agent_id),
         {:ok, _pid} <- start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
      {:ok, persisted_thread}
    end
  end

  defp unassign_thread_state(runtime, room_server, updated_thread) do
    with {:ok, persisted_thread} <- save_thread_struct(runtime, updated_thread),
         :ok <- room_server_unassign_thread(room_server, updated_thread.id) do
      {:ok, persisted_thread}
    end
  end

  defp rollback_thread_assignment(
         instance_module,
         runtime,
         room_server,
         %Thread{} = original_thread,
         previous_agent_spec
       ) do
    with {:ok, _thread} <- save_thread_struct(runtime, original_thread),
         :ok <- restore_room_server_assignment(room_server, original_thread, previous_agent_spec),
         :ok <- restore_thread_runner(instance_module, original_thread, previous_agent_spec) do
      :ok
    end
  end

  defp restore_room_server_assignment(room_server, %Thread{assigned_agent_id: agent_id} = thread, agent_spec)
       when is_binary(agent_id) and is_map(agent_spec) do
    with {:ok, _registered_agent} <- room_server_register_agent(room_server, agent_spec),
         :ok <- restore_room_server_assignment(room_server, %{thread | assigned_agent_id: agent_id}, nil) do
      :ok
    end
  end

  defp restore_room_server_assignment(room_server, %Thread{id: thread_id, assigned_agent_id: agent_id}, _agent_spec)
       when is_binary(agent_id) do
    room_server_assign_thread(room_server, thread_id, agent_id)
  end

  defp restore_room_server_assignment(room_server, %Thread{id: thread_id}, _agent_spec) do
    room_server_unassign_thread(room_server, thread_id)
  end

  defp restore_thread_runner(_instance_module, %Thread{assigned_agent_id: nil}, _previous_agent_spec), do: :ok

  defp restore_thread_runner(
         instance_module,
         %Thread{room_id: room_id, id: thread_id, assigned_agent_id: agent_id},
         agent_spec
       )
       when is_binary(agent_id) and is_map(agent_spec) do
    case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp restore_thread_runner(_instance_module, %Thread{assigned_agent_id: _agent_id}, _previous_agent_spec), do: :ok

  defp registered_agent_spec(_instance_module, _room_id, _thread_id, _room_server, nil), do: nil

  defp registered_agent_spec(instance_module, room_id, thread_id, room_server, agent_id) when is_binary(agent_id) do
    case room_server_get_agent(room_server, agent_id) do
      {:ok, agent_spec} ->
        agent_spec

      {:error, _reason} ->
        case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
          pid when is_pid(pid) ->
            case runner_agent_spec(pid, agent_id) do
              {:ok, agent_spec} -> agent_spec
              {:error, _reason} -> nil
            end

          nil ->
            nil
        end
    end
  end

  defp start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
    case AgentSupervisor.start_agent(instance_module, room_id, thread_id, agent_id, agent_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_agent_failed, reason}}
    end
  end

  defp stop_thread_runner(_instance_module, _room_id, _thread_id, nil), do: :ok

  defp stop_thread_runner(instance_module, room_id, thread_id, agent_id) when is_binary(agent_id) do
    case AgentSupervisor.stop_agent(instance_module, room_id, thread_id, agent_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:stop_agent_failed, reason}}
    end
  end

  defp room_server_get_agent(room_server, agent_id) do
    try do
      RoomServer.get_agent(room_server, agent_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_assign_thread(room_server, thread_id, agent_id) do
    try do
      RoomServer.assign_thread(room_server, thread_id, agent_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_unassign_thread(room_server, thread_id) do
    try do
      RoomServer.unassign_thread(room_server, thread_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_thread_assignment(room_server, thread_id) do
    case room_server_thread_assignment_result(room_server, thread_id) do
      {:ok, assignment} -> assignment
      {:error, _reason} -> nil
    end
  end

  defp room_server_thread_assignment_result(room_server, thread_id) do
    try do
      {:ok, RoomServer.thread_assignment(room_server, thread_id)}
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_list_thread_assignments(room_server) do
    try do
      {:ok, RoomServer.list_thread_assignments(room_server)}
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_list_agents(room_server) do
    try do
      {:ok, RoomServer.list_agents(room_server)}
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_register_agent(room_server, agent_spec) when is_map(agent_spec) do
    try do
      RoomServer.register_agent(room_server, agent_spec)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp room_server_unregister_agent(room_server, agent_id) do
    try do
      RoomServer.unregister_agent(room_server, agent_id)
    catch
      :exit, reason -> {:error, {:room_server_unavailable, reason}}
    end
  end

  defp runner_agent_spec(pid, fallback_agent_id) when is_pid(pid) and is_binary(fallback_agent_id) do
    try do
      case AgentRunner.get_state(pid) do
        %AgentRunner{agent_id: agent_id, agent_config: agent_config} when is_map(agent_config) ->
          {:ok,
           agent_config
           |> Map.put(:agent_id, agent_id || fallback_agent_id)
           |> Map.put_new(:name, fallback_agent_id)}

        _other ->
          {:error, :runner_state_unavailable}
      end
    catch
      :exit, reason -> {:error, {:runner_unavailable, reason}}
    end
  end

  defp maybe_touch_thread_assignment(%Thread{assigned_agent_id: agent_id} = thread, agent_id), do: thread

  defp maybe_touch_thread_assignment(%Thread{} = thread, agent_id) do
    %{thread | assigned_agent_id: agent_id, updated_at: DateTime.utc_now()}
  end

  defp ensure_thread_room(%Thread{room_id: room_id}, room_id), do: :ok
  defp ensure_thread_room(%Thread{}, _room_id), do: {:error, :thread_room_mismatch}

  defp ensure_room_server(instance_module, room_id) do
    runtime = runtime_name(instance_module)

    with {:ok, room} <- get_room(runtime, room_id) do
      RoomSupervisor.get_or_start_room(instance_module, room)
    end
  end

  defp runtime_name(instance_module), do: Module.concat(instance_module, :Runtime)

  defp validate_history_scope(
         instance_module,
         %Jido.Messaging.HistoryScope{instance_module: instance_module, room_ids: room_ids}
       )
       when is_list(room_ids),
       do: :ok

  defp validate_history_scope(_instance_module, %Jido.Messaging.HistoryScope{}) do
    {:error, :history_scope_instance_mismatch}
  end

  defp validate_history_scope(_instance_module, _scope), do: {:error, :history_scope_required}

  defp validate_history_room(scope, room_id) do
    if room_id in scope.room_ids, do: :ok, else: {:error, :history_scope_violation}
  end

  defp search_projection(instance_module, opts) do
    projection =
      Keyword.get(opts, :projection) ||
        Application.get_env(instance_module, :search_projection) ||
        Application.get_env(:jido_messaging, :search_projection)

    if is_atom(projection) and not is_nil(projection) do
      {:ok, projection}
    else
      {:error, :search_projection_not_configured}
    end
  end

  defp validate_projection(projection) do
    callbacks = [upsert: 3, delete: 3, search: 3, rebuild: 3]

    if Code.ensure_loaded?(projection) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(projection, name, arity) end) do
      :ok
    else
      {:error, :invalid_search_projection}
    end
  end

  defp validate_projection_results(entries, instance_module, scope) when is_list(entries) do
    allowed_rooms = MapSet.new(scope.room_ids)

    if Enum.all?(entries, fn
         %Jido.Messaging.TranscriptEntry{instance_module: ^instance_module, room_id: room_id} = entry ->
           MapSet.member?(allowed_rooms, room_id) and projection_entry_consistent?(entry)

         _other ->
           false
       end) do
      :ok
    else
      {:error, :search_projection_scope_violation}
    end
  end

  defp validate_projection_results(_entries, _instance_module, _scope) do
    {:error, :invalid_search_projection_result}
  end

  defp projection_entry_consistent?(%Jido.Messaging.TranscriptEntry{
         canonical_message_id: canonical_message_id,
         canonical_participant_id: canonical_participant_id,
         room_id: room_id,
         provider_message_id: provider_message_id,
         inserted_at: inserted_at,
         message: %Message{} = message
       }) do
    message.id == canonical_message_id and
      message.sender_id == canonical_participant_id and
      message.room_id == room_id and
      message.external_id == provider_message_id and
      message.inserted_at == inserted_at
  end

  defp projection_entry_consistent?(_entry), do: false

  defp collect_transcript(instance_module, runtime, participant_id, scope, opts) do
    batch_size = opts |> Keyword.get(:batch_size, 500) |> normalize_transcript_batch_size()

    page_opts =
      opts
      |> Keyword.drop([:projection, :batch_size, :before, :after])
      |> Keyword.put(:limit, batch_size)

    with {:ok, latest} <- participant_transcript(instance_module, runtime, participant_id, scope, page_opts) do
      collect_older_transcript(instance_module, runtime, participant_id, scope, page_opts, latest)
    end
  end

  defp collect_older_transcript(_instance_module, _runtime, _participant_id, _scope, _opts, []), do: {:ok, []}

  defp collect_older_transcript(instance_module, runtime, participant_id, scope, opts, entries) do
    before = entries |> List.first() |> Map.fetch!(:canonical_message_id)

    case participant_transcript(instance_module, runtime, participant_id, scope, Keyword.put(opts, :before, before)) do
      {:ok, []} ->
        {:ok, entries}

      {:ok, older} ->
        with {:ok, all_older} <-
               collect_older_transcript(instance_module, runtime, participant_id, scope, opts, older) do
          {:ok, all_older ++ entries}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_transcript_batch_size(value) when is_integer(value) and value > 0, do: min(value, 1_000)
  defp normalize_transcript_batch_size(_value), do: 500

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
