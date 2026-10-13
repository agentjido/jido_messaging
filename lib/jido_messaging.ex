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

  Use a typed request to persist a message and notify consumers:

      request = Jido.Messaging.Signal.PostMessage.new!(%{
        "request_id" => "post-1",
        "room_id" => room.id,
        "sender_id" => "user_123",
        "text" => "Hello!"
      })
      actor = [principal_id: "user_123", authorization_scope: room_scope]
      {:ok, %Jido.Signal{}} = MyApp.Messaging.execute(request, actor)

  The trusted principal needs an active grant for the room scope.
  The instance Bus publishes registered facts and results.
  `save_message/1` is a low-level record operation.
  """

  @doc "Returns the explicit public Signal definition list for this domain."
  @spec signal_definitions() :: [module()]
  def signal_definitions do
    [
      Jido.Messaging.Signal.SendMessage,
      Jido.Messaging.Signal.SendFile,
      Jido.Messaging.Signal.PostProviderMessage,
      Jido.Messaging.Signal.EditMessage,
      Jido.Messaging.Signal.DeleteMessage,
      Jido.Messaging.Signal.StartTyping,
      Jido.Messaging.Signal.FetchMetadata,
      Jido.Messaging.Signal.FetchThread,
      Jido.Messaging.Signal.FetchMessage,
      Jido.Messaging.Signal.GetUser,
      Jido.Messaging.Signal.FetchSubject,
      Jido.Messaging.Signal.GetThreadParticipants,
      Jido.Messaging.Signal.MarkAsRead,
      Jido.Messaging.Signal.FetchMedia,
      Jido.Messaging.Signal.AddReaction,
      Jido.Messaging.Signal.RemoveReaction,
      Jido.Messaging.Signal.PostEphemeral,
      Jido.Messaging.Signal.PostChannelMessage,
      Jido.Messaging.Signal.Stream,
      Jido.Messaging.Signal.OpenModal,
      Jido.Messaging.Signal.LoadOptions,
      Jido.Messaging.Signal.FetchMessages,
      Jido.Messaging.Signal.FetchChannelMessages,
      Jido.Messaging.Signal.ListThreads,
      Jido.Messaging.Signal.OpenThread,
      Jido.Messaging.Signal.OpenDm,
      Jido.Messaging.Signal.RoomMessageAdded,
      Jido.Messaging.Signal.MessageReceived,
      Jido.Messaging.Signal.MessageSent,
      Jido.Messaging.Signal.MessageFailed,
      Jido.Messaging.Signal.RoomCreated,
      Jido.Messaging.Signal.ParticipantJoined,
      Jido.Messaging.Signal.ParticipantLeft,
      Jido.Messaging.Signal.PresenceChanged,
      Jido.Messaging.Signal.TypingChanged,
      Jido.Messaging.Signal.ReactionAdded,
      Jido.Messaging.Signal.ReactionRemoved,
      Jido.Messaging.Signal.MessageDelivered,
      Jido.Messaging.Signal.MessageRead,
      Jido.Messaging.Signal.ThreadCreated,
      Jido.Messaging.Signal.ThreadReplyAdded,
      Jido.Messaging.Signal.AgentTriggered,
      Jido.Messaging.Signal.AgentStarted,
      Jido.Messaging.Signal.AgentCompleted,
      Jido.Messaging.Signal.AgentFailed,
      Jido.Messaging.Signal.InstanceStarted,
      Jido.Messaging.Signal.InstanceConnecting,
      Jido.Messaging.Signal.InstanceConnected,
      Jido.Messaging.Signal.InstanceDisconnected,
      Jido.Messaging.Signal.InstanceStopped,
      Jido.Messaging.Signal.InstanceError,
      Jido.Messaging.Signal.MembershipObserved,
      Jido.Messaging.Signal.PostMessage,
      Jido.Messaging.Signal.CreateRoom,
      Jido.Messaging.Signal.ParticipantJoinedRequest,
      Jido.Messaging.Signal.ParticipantLeftRequest,
      Jido.Messaging.Signal.SetPresence,
      Jido.Messaging.Signal.SetTyping,
      Jido.Messaging.Signal.AddRoomReaction,
      Jido.Messaging.Signal.RemoveRoomReaction,
      Jido.Messaging.Signal.MarkDelivered,
      Jido.Messaging.Signal.MarkRead,
      Jido.Messaging.Signal.OperationCompleted,
      Jido.Messaging.Signal.OperationFailed,
      Jido.Messaging.Signal.ThreadChanged
    ]
  end

  @doc "Executes a typed request with trusted principal and authorization scope options."
  @spec execute(module(), Jido.Signal.t(), keyword()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def execute(instance, request, opts), do: Jido.Messaging.Execution.execute(instance, request, opts)

  @doc "Accepts a complete validated provider delivery through the runtime owner."
  @spec accept_delivery(module(), Jido.Chat.Delivery.t()) :: {:ok, [Jido.Signal.t()]} | {:error, term()}
  def accept_delivery(instance, delivery), do: Jido.Messaging.Acceptance.accept(instance, delivery)

  @doc "Resolves a private resource for the call that created its reference."
  @spec resolve_resource(module(), map()) :: {:ok, term()} | {:error, term()}
  def resolve_resource(instance, ref) do
    with {:ok, owner} <- resource_owner(instance, ref), do: Jido.Chat.Resources.resolve(owner, ref)
  end

  @doc "Cancels a private call-scoped resource and clears its value."
  @spec cancel_resource(module(), map()) :: :ok | {:error, term()}
  def cancel_resource(instance, ref) do
    with {:ok, owner} <- resource_owner(instance, ref), do: Jido.Chat.Resources.cancel(owner, ref)
  end

  defp resource_owner(instance, %{"binding_id" => id}) do
    runtime = instance.__jido_messaging__(:runtime)
    owner = Jido.Messaging.Runtime.resource_owner(runtime)

    if owner.id == id do
      {:ok, owner}
    else
      case Jido.Messaging.Runtime.binding(runtime, id) do
        {:ok, _} = result -> result
        _ -> Jido.Chat.Signal.Policy.error(:invalid_resource)
      end
    end
  rescue
    _ -> Jido.Chat.Signal.Policy.error(:invalid_resource)
  catch
    _, _ -> Jido.Chat.Signal.Policy.error(:resource_expired)
  end

  defp resource_owner(_instance, _ref), do: Jido.Chat.Signal.Policy.error(:invalid_resource)

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.BridgeRoomSpec
  alias Jido.Messaging.TopologyValidator

  alias Jido.Messaging.{
    AccessControl,
    AgentEndpoints,
    AgentRunner,
    AgentSupervisor,
    ActivityProjection,
    ConfigStore,
    IdentityCredentials,
    IdentityVerifier,
    IngressSubscriptions,
    ExternalIdentityBinding,
    Identity,
    Message,
    Onboarding,
    Principal,
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

      @doc "Executes a typed request with trusted actor options."
      def execute(request, opts), do: Jido.Messaging.execute(__MODULE__, request, opts)

      @doc "Accepts a complete normalized Chat delivery."
      def accept_delivery(delivery), do: Jido.Messaging.accept_delivery(__MODULE__, delivery)

      @doc "Resolves a private resource for its creator call."
      def resolve_resource(ref), do: Jido.Messaging.resolve_resource(__MODULE__, ref)

      @doc "Cancels a private call-scoped resource."
      def cancel_resource(ref), do: Jido.Messaging.cancel_resource(__MODULE__, ref)

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

      @doc "Create an optional controller credential for a messaging principal"
      def create_identity_credential(attrs) do
        Jido.Messaging.create_identity_credential(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a controller credential by ID"
      def get_identity_credential(credential_id) do
        Jido.Messaging.get_identity_credential(__jido_messaging__(:runtime), credential_id)
      end

      @doc "List controller credentials for one subject principal"
      def list_identity_credentials(subject_principal_id, opts \\ []) do
        Jido.Messaging.list_identity_credentials(
          __jido_messaging__(:runtime),
          subject_principal_id,
          opts
        )
      end

      @doc "Suspend a controller credential with an expected revision"
      def suspend_identity_credential(credential_id, expected_revision) do
        Jido.Messaging.suspend_identity_credential(
          __jido_messaging__(:runtime),
          credential_id,
          expected_revision
        )
      end

      @doc "Activate a suspended controller credential with an expected revision"
      def activate_identity_credential(credential_id, expected_revision) do
        Jido.Messaging.activate_identity_credential(
          __jido_messaging__(:runtime),
          credential_id,
          expected_revision
        )
      end

      @doc "Revoke a controller credential with an expected revision"
      def revoke_identity_credential(credential_id, expected_revision, opts \\ []) do
        Jido.Messaging.revoke_identity_credential(
          __jido_messaging__(:runtime),
          credential_id,
          expected_revision,
          opts
        )
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

      @doc "Rotate a controller credential without changing its principal relation"
      def rotate_identity_credential(credential_id, expected_revision, attrs) do
        Jido.Messaging.rotate_identity_credential(
          __jido_messaging__(:runtime),
          credential_id,
          expected_revision,
          attrs
        )
      end

      @doc "Create a durable messaging endpoint for one Jidoka agent principal"
      def create_agent_messaging_endpoint(attrs) do
        Jido.Messaging.create_agent_messaging_endpoint(__jido_messaging__(:runtime), attrs)
      end

      @doc "Persist an updated Jidoka agent messaging endpoint"
      def save_agent_messaging_endpoint(endpoint) do
        Jido.Messaging.save_agent_messaging_endpoint(__jido_messaging__(:runtime), endpoint)
      end

      @doc "Get an agent messaging endpoint by record ID"
      def get_agent_messaging_endpoint(endpoint_id) do
        Jido.Messaging.get_agent_messaging_endpoint(__jido_messaging__(:runtime), endpoint_id)
      end

      @doc "Get an agent messaging endpoint by Jidoka agent ID"
      def get_agent_messaging_endpoint_by_ref(jidoka_agent_id) do
        Jido.Messaging.get_agent_messaging_endpoint_by_ref(
          __jido_messaging__(:runtime),
          jidoka_agent_id
        )
      end

      @doc "List durable Jidoka agent messaging endpoints"
      def list_agent_messaging_endpoints(opts \\ []) do
        Jido.Messaging.list_agent_messaging_endpoints(__jido_messaging__(:runtime), opts)
      end

      @doc "Update an endpoint availability projection"
      def set_agent_endpoint_availability(endpoint_id, availability, opts \\ []) do
        Jido.Messaging.set_agent_endpoint_availability(
          __jido_messaging__(:runtime),
          endpoint_id,
          availability,
          opts
        )
      end

      @doc "Create or replace the canonical principal for an existing participant"
      def create_principal(attrs) do
        Jido.Messaging.create_principal(__jido_messaging__(:runtime), attrs)
      end

      @doc "Persist an already-constructed canonical principal"
      def save_principal(%Jido.Messaging.Principal{} = principal) do
        Jido.Messaging.save_principal(__jido_messaging__(:runtime), principal)
      end

      @doc "Get a canonical principal by ID"
      def get_principal(principal_id) do
        Jido.Messaging.get_principal(__jido_messaging__(:runtime), principal_id)
      end

      @doc "Get or create the principal projection for a participant"
      def principal_for_participant(participant_id) do
        Jido.Messaging.principal_for_participant(
          __jido_messaging__(:runtime),
          participant_id
        )
      end

      @doc "Bind a bridge-scoped provider identity to a canonical principal"
      def bind_external_identity(principal_id, channel, bridge_id, external_id, opts \\ []) do
        Jido.Messaging.bind_external_identity(
          __jido_messaging__(:runtime),
          principal_id,
          channel,
          bridge_id,
          external_id,
          opts
        )
      end

      @doc "Revoke an agent messaging endpoint"
      def revoke_agent_messaging_endpoint(endpoint_id, opts \\ []) do
        Jido.Messaging.revoke_agent_messaging_endpoint(
          __jido_messaging__(:runtime),
          endpoint_id,
          opts
        )
      end

      @doc "Get an external identity binding by record ID"
      def get_external_identity_binding(binding_id) do
        Jido.Messaging.get_external_identity_binding(
          __jido_messaging__(:runtime),
          binding_id
        )
      end

      @doc "Get an external identity binding by provider scope"
      def get_external_identity_binding(channel, bridge_id, external_id) do
        Jido.Messaging.get_external_identity_binding(
          __jido_messaging__(:runtime),
          channel,
          bridge_id,
          external_id
        )
      end

      @doc "List external identity bindings for a principal"
      def list_external_identity_bindings(principal_id, opts \\ []) do
        Jido.Messaging.list_external_identity_bindings(
          __jido_messaging__(:runtime),
          principal_id,
          opts
        )
      end

      @doc "Add an agent endpoint to a room without granting messaging actions"
      def add_agent_endpoint_to_room(endpoint_id, room_id, opts \\ []) do
        Jido.Messaging.add_agent_endpoint_to_room(
          __jido_messaging__(:runtime),
          endpoint_id,
          room_id,
          opts
        )
      end

      @doc "Revoke an external identity binding"
      def revoke_external_identity_binding(binding_id, opts \\ []) do
        Jido.Messaging.revoke_external_identity_binding(
          __jido_messaging__(:runtime),
          binding_id,
          opts
        )
      end

      @doc "Get an agent endpoint room membership"
      def get_agent_room_membership(membership_id) do
        Jido.Messaging.get_agent_room_membership(
          __jido_messaging__(:runtime),
          membership_id
        )
      end

      @doc "List agent endpoint memberships for a room"
      def list_agent_room_memberships(room_id, opts \\ []) do
        Jido.Messaging.list_agent_room_memberships(
          __jido_messaging__(:runtime),
          room_id,
          opts
        )
      end

      @doc "Revoke an agent endpoint room membership"
      def revoke_agent_room_membership(membership_id, opts \\ []) do
        Jido.Messaging.revoke_agent_room_membership(
          __jido_messaging__(:runtime),
          membership_id,
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

      @doc "Verify one controller proof and return separate identity evidence"
      def verify_identity_credential(credential_id, proof, context, opts \\ []) do
        Jido.Messaging.verify_identity_credential(
          __jido_messaging__(:runtime),
          credential_id,
          proof,
          context,
          opts
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

      @doc "Verify a controller credential, or return lower assurance when it is absent"
      def verify_optional_identity(credential_id, proof, context, opts \\ []) do
        Jido.Messaging.verify_optional_identity(
          __jido_messaging__(:runtime),
          credential_id,
          proof,
          context,
          opts
        )
      end

      @doc "Route a thread to a durable agent endpoint without starting an agent"
      def route_thread_to_agent_endpoint(thread_id, endpoint_id, opts \\ []) do
        Jido.Messaging.route_thread_to_agent_endpoint(
          __jido_messaging__(:runtime),
          thread_id,
          endpoint_id,
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

      @doc "Get the durable agent endpoint route for a thread"
      def get_agent_thread_route(thread_id) do
        Jido.Messaging.get_agent_thread_route(__jido_messaging__(:runtime), thread_id)
      end

      @doc "List durable thread routes for an agent endpoint"
      def list_agent_thread_routes(endpoint_id, opts \\ []) do
        Jido.Messaging.list_agent_thread_routes(
          __jido_messaging__(:runtime),
          endpoint_id,
          opts
        )
      end

      @doc "Update opaque Jidoka correlation references for a thread route"
      def put_agent_thread_route_correlations(thread_id, correlations) do
        Jido.Messaging.put_agent_thread_route_correlations(
          __jido_messaging__(:runtime),
          thread_id,
          correlations
        )
      end

      @doc "Revoke a durable agent endpoint route"
      def revoke_agent_thread_route(thread_id, opts \\ []) do
        Jido.Messaging.revoke_agent_thread_route(
          __jido_messaging__(:runtime),
          thread_id,
          opts
        )
      end

      @doc "Resolve an available endpoint, membership, and route for a thread"
      def resolve_agent_thread_endpoint(thread_id) do
        Jido.Messaging.resolve_agent_thread_endpoint(
          __jido_messaging__(:runtime),
          thread_id
        )
      end

      @doc "Save a message"
      def save_message(attrs) do
        Jido.Messaging.save_message(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a message by ID"
      def get_message(message_id) do
        Jido.Messaging.get_message(__jido_messaging__(:runtime), message_id)
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

      @doc "Build an exact authorization scope for Jidoka delegation transport"
      def jidoka_delegation_scope(attrs) do
        Jido.Messaging.JidokaDelegationScope.new(__MODULE__, attrs)
      end

      @doc "Record one authorized Jidoka-emitted delegation observation"
      def record_jidoka_delegation_event(attrs, scope) do
        Jido.Messaging.record_jidoka_delegation_event(
          __MODULE__,
          __jido_messaging__(:runtime),
          attrs,
          scope
        )
      end

      @doc "Create or update a messaging reference to Jidoka-owned continuity"
      def put_thread_continuity(attrs) do
        Jido.Messaging.put_thread_continuity(__jido_messaging__(:runtime), attrs)
      end

      @doc "Get a thread continuity link within an authorized history scope"
      def get_thread_continuity(thread_id, scope) do
        Jido.Messaging.get_thread_continuity(
          __MODULE__,
          __jido_messaging__(:runtime),
          thread_id,
          scope
        )
      end

      @doc "Get a Jidoka delegation event within its exact scope"
      def get_jidoka_delegation_event(event_id, scope) do
        Jido.Messaging.get_jidoka_delegation_event(
          __MODULE__,
          __jido_messaging__(:runtime),
          event_id,
          scope
        )
      end

      @doc "Resolve a usable opaque Jidoka continuity reference"
      def resolve_thread_continuity(thread_id, scope) do
        Jido.Messaging.resolve_thread_continuity(
          __MODULE__,
          __jido_messaging__(:runtime),
          thread_id,
          scope
        )
      end

      @doc "Get authorized canonical messages named by a Jidoka delegation event"
      def jidoka_delegation_context(event_id, scope) do
        Jido.Messaging.jidoka_delegation_context(
          __MODULE__,
          __jido_messaging__(:runtime),
          event_id,
          scope
        )
      end

      @doc "Change the availability state of a thread continuity link"
      def set_thread_continuity_status(thread_id, status, expected_revision, opts \\ []) do
        Jido.Messaging.set_thread_continuity_status(
          __jido_messaging__(:runtime),
          thread_id,
          status,
          expected_revision,
          opts
        )
      end

      @doc "Clear a thread continuity link and keep a durable marker"
      def clear_thread_continuity(thread_id, expected_revision, opts \\ []) do
        Jido.Messaging.clear_thread_continuity(
          __jido_messaging__(:runtime),
          thread_id,
          expected_revision,
          opts
        )
      end

      @doc "Return a scoped canonical transcript and its opaque Jidoka link"
      def jidoka_continuity_context(thread_id, scope, opts \\ []) do
        Jido.Messaging.jidoka_continuity_context(
          __MODULE__,
          __jido_messaging__(:runtime),
          thread_id,
          scope,
          opts
        )
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

      @doc "Build an exact authorization and membership scope for advisory trust evidence"
      def trust_evidence_scope(attrs) do
        Jido.Messaging.TrustEvidenceScope.new(__MODULE__, attrs)
      end

      @doc "Record one scoped advisory trust-evidence revision"
      def record_trust_evidence(attrs, scope) do
        Jido.Messaging.record_trust_evidence(
          __MODULE__,
          __jido_messaging__(:runtime),
          attrs,
          scope
        )
      end

      @doc "Query advisory trust evidence without ranking or selecting an agent"
      def query_trust_evidence(scope, opts \\ []) do
        Jido.Messaging.query_trust_evidence(
          __MODULE__,
          __jido_messaging__(:runtime),
          scope,
          opts
        )
      end

      @doc "Store a safe messaging activity projection from a trusted Jidoka adapter"
      def project_messaging_activity(attrs) do
        Jido.Messaging.project_messaging_activity(__jido_messaging__(:runtime), attrs)
      end

      @doc "Return Jidoka-linked activity for one principal inside explicit room scope"
      def principal_activity(principal_id, scope, opts \\ []) do
        Jido.Messaging.principal_activity(
          __MODULE__,
          __jido_messaging__(:runtime),
          principal_id,
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

      @doc "Get a provider message within one canonical room."
      def get_message_by_external_id(channel, bridge_id, external_id, room_id) do
        Jido.Messaging.get_message_by_external_id(
          __jido_messaging__(:runtime),
          channel,
          bridge_id,
          external_id,
          room_id
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
      def directory_lookup(target, query, opts \\ [])

      def directory_lookup(:agent, query, opts) do
        case Keyword.fetch(opts, :scope) do
          {:ok, scope} ->
            Jido.Messaging.AgentDirectory.lookup(
              __MODULE__,
              __jido_messaging__(:runtime),
              query,
              scope,
              Keyword.delete(opts, :scope)
            )

          :error ->
            {:error, :agent_directory_scope_required}
        end
      end

      def directory_lookup(target, query, opts) do
        Jido.Messaging.directory_lookup(__jido_messaging__(:runtime), target, query, opts)
      end

      @doc "Search directory entries."
      def directory_search(target, query, opts \\ [])

      def directory_search(:agent, query, opts) do
        case Keyword.fetch(opts, :scope) do
          {:ok, scope} ->
            Jido.Messaging.AgentDirectory.search(
              __MODULE__,
              __jido_messaging__(:runtime),
              query,
              scope,
              Keyword.delete(opts, :scope)
            )

          :error ->
            {:error, :agent_directory_scope_required}
        end
      end

      def directory_search(target, query, opts) do
        Jido.Messaging.directory_search(__jido_messaging__(:runtime), target, query, opts)
      end

      @doc "Publish a safe Jidoka agent projection into the messaging directory."
      def project_jidoka_agent(attrs) do
        Jido.Messaging.AgentDirectory.project(__jido_messaging__(:runtime), attrs)
      end

      @doc "Publish a safe Jidoka agent projection through a Jidoka-owned adapter."
      def project_jidoka_agent_from(projector, source, context \\ %{}, opts \\ []) do
        Jido.Messaging.AgentDirectory.project_from(
          __jido_messaging__(:runtime),
          projector,
          source,
          context,
          opts
        )
      end

      @doc "Get a stored Jidoka agent directory projection by ID."
      def get_jidoka_agent_projection(projection_id) do
        Jido.Messaging.AgentDirectory.get(__jido_messaging__(:runtime), projection_id)
      end

      @doc "Build an explicit agent directory scope for this messaging instance."
      def agent_directory_scope(endpoint_principals, metadata \\ %{}) do
        Jido.Messaging.AgentDirectoryScope.new(__MODULE__, endpoint_principals, metadata)
      end

      @doc "Search safe Jidoka agent projections within an explicit scope."
      def search_jidoka_agents(query, scope, opts \\ []) do
        Jido.Messaging.AgentDirectory.search(
          __MODULE__,
          __jido_messaging__(:runtime),
          query,
          scope,
          opts
        )
      end

      @doc "Lookup one safe Jidoka agent projection within an explicit scope."
      def lookup_jidoka_agent(query, scope, opts \\ []) do
        Jido.Messaging.AgentDirectory.lookup(
          __MODULE__,
          __jido_messaging__(:runtime),
          query,
          scope,
          opts
        )
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

      @doc "Register a legacy in-memory agent handler with a room"
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

      @doc "Create or ensure a bridge-backed room topology in one call."
      def create_bridge_room(attrs) do
        Jido.Messaging.create_bridge_room(__MODULE__, attrs)
      end

      # Outbound routing functions

      @doc "Resolve configured outbound adapter routes for a room."
      def resolve_outbound_routes(room_id, opts \\ []) do
        Jido.Messaging.resolve_outbound_routes(__MODULE__, room_id, opts)
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

      @doc "Get persistence guarantees for this messaging runtime."
      def persistence_capabilities do
        Jido.Messaging.Runtime.persistence_capabilities(__jido_messaging__(:runtime))
      end

      @doc "Check this messaging runtime's persistence connection and schema."
      def persistence_health do
        Jido.Messaging.Runtime.persistence_health(__jido_messaging__(:runtime))
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

      # Native Signal subscriptions

      @doc "Subscribe to Jido Signal events emitted by this messaging instance"
      def subscribe_signals(path \\ "jido.messaging.**", opts \\ []) do
        Jido.Messaging.subscribe_signals(__MODULE__, path, opts)
      end

      @doc "Unsubscribe from a Jido Signal Bus subscription"
      def unsubscribe_signals(subscription_id, opts \\ []) do
        Jido.Messaging.unsubscribe_signals(__MODULE__, subscription_id, opts)
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

  @doc "Create an optional controller credential for a messaging principal."
  def create_identity_credential(runtime, attrs) when is_atom(runtime) and is_map(attrs),
    do: IdentityCredentials.create(runtime, attrs)

  @doc "Get a controller credential by ID."
  def get_identity_credential(runtime, credential_id)
      when is_atom(runtime) and is_binary(credential_id),
      do: IdentityCredentials.get(runtime, credential_id)

  @doc "List controller credentials for one subject principal."
  def list_identity_credentials(runtime, subject_principal_id, opts \\ [])
      when is_atom(runtime) and is_binary(subject_principal_id) and is_list(opts),
      do: IdentityCredentials.list(runtime, subject_principal_id, opts)

  @doc "Suspend a controller credential with an expected revision."
  def suspend_identity_credential(runtime, credential_id, expected_revision)
      when is_atom(runtime) and is_binary(credential_id) and is_integer(expected_revision),
      do: IdentityCredentials.transition(runtime, credential_id, expected_revision, :suspended)

  @doc "Activate a suspended controller credential with an expected revision."
  def activate_identity_credential(runtime, credential_id, expected_revision)
      when is_atom(runtime) and is_binary(credential_id) and is_integer(expected_revision),
      do: IdentityCredentials.transition(runtime, credential_id, expected_revision, :active)

  @doc "Revoke a controller credential with an expected revision."
  def revoke_identity_credential(runtime, credential_id, expected_revision, opts \\ [])
      when is_atom(runtime) and is_binary(credential_id) and is_integer(expected_revision) and
             is_list(opts),
      do: IdentityCredentials.transition(runtime, credential_id, expected_revision, :revoked, opts)

  @doc "Rotate a controller credential without changing its principal relation."
  def rotate_identity_credential(runtime, credential_id, expected_revision, attrs)
      when is_atom(runtime) and is_binary(credential_id) and is_integer(expected_revision) and
             is_map(attrs),
      do: IdentityCredentials.rotate(runtime, credential_id, expected_revision, attrs)

  @doc "Verify one controller proof and return separate identity evidence."
  def verify_identity_credential(runtime, credential_id, proof, context, opts \\ [])
      when is_atom(runtime) and is_binary(credential_id) and is_map(proof) and is_map(context) and
             is_list(opts),
      do: IdentityVerifier.verify(runtime, credential_id, proof, context, opts)

  @doc "Verify a controller credential, or return lower assurance when it is absent."
  def verify_optional_identity(runtime, credential_id, proof, context, opts \\ [])
      when is_atom(runtime) and (is_binary(credential_id) or is_nil(credential_id)) and is_map(proof) and
             is_map(context) and is_list(opts),
      do: IdentityVerifier.verify_optional(runtime, credential_id, proof, context, opts)

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

  @doc "Create a durable messaging endpoint for one Jidoka agent principal."
  def create_agent_messaging_endpoint(runtime, attrs) when is_map(attrs),
    do: AgentEndpoints.create_endpoint(runtime, attrs)

  @doc "Persist an updated Jidoka agent messaging endpoint."
  def save_agent_messaging_endpoint(runtime, %Jido.Messaging.AgentMessagingEndpoint{} = endpoint),
    do: AgentEndpoints.save_endpoint(runtime, endpoint)

  @doc "Get an agent messaging endpoint by record ID."
  def get_agent_messaging_endpoint(runtime, endpoint_id) when is_binary(endpoint_id),
    do: AgentEndpoints.get_endpoint(runtime, endpoint_id)

  @doc "Get an agent messaging endpoint by Jidoka agent ID."
  def get_agent_messaging_endpoint_by_ref(runtime, jidoka_agent_id) when is_binary(jidoka_agent_id),
    do: AgentEndpoints.get_endpoint_by_ref(runtime, jidoka_agent_id)

  @doc "List durable Jidoka agent messaging endpoints."
  def list_agent_messaging_endpoints(runtime, opts \\ []) when is_list(opts),
    do: AgentEndpoints.list_endpoints(runtime, opts)

  @doc "Update an endpoint availability projection."
  def set_agent_endpoint_availability(runtime, endpoint_id, availability, opts \\ [])
      when is_binary(endpoint_id) and is_list(opts),
      do: AgentEndpoints.set_availability(runtime, endpoint_id, availability, opts)

  @doc "Revoke an agent messaging endpoint."
  def revoke_agent_messaging_endpoint(runtime, endpoint_id, opts \\ [])
      when is_binary(endpoint_id) and is_list(opts),
      do: AgentEndpoints.revoke_endpoint(runtime, endpoint_id, opts)

  @doc "Add an agent endpoint to a room without granting messaging actions."
  def add_agent_endpoint_to_room(runtime, endpoint_id, room_id, opts \\ [])
      when is_binary(endpoint_id) and is_binary(room_id) and is_list(opts),
      do: AgentEndpoints.add_endpoint_to_room(runtime, endpoint_id, room_id, opts)

  @doc "Get an agent endpoint room membership by record ID."
  def get_agent_room_membership(runtime, membership_id) when is_binary(membership_id),
    do: AgentEndpoints.get_membership(runtime, membership_id)

  @doc "List agent endpoint memberships for a room."
  def list_agent_room_memberships(runtime, room_id, opts \\ [])
      when is_binary(room_id) and is_list(opts),
      do: AgentEndpoints.list_memberships(runtime, room_id, opts)

  @doc "Revoke an agent endpoint room membership."
  def revoke_agent_room_membership(runtime, membership_id, opts \\ [])
      when is_binary(membership_id) and is_list(opts),
      do: AgentEndpoints.revoke_membership(runtime, membership_id, opts)

  @doc "Route a thread to a durable agent endpoint without starting an agent."
  def route_thread_to_agent_endpoint(runtime, thread_id, endpoint_id, opts \\ [])
      when is_binary(thread_id) and is_binary(endpoint_id) and is_list(opts),
      do: AgentEndpoints.route_thread(runtime, thread_id, endpoint_id, opts)

  @doc "Get the durable agent endpoint route for a thread."
  def get_agent_thread_route(runtime, thread_id) when is_binary(thread_id),
    do: AgentEndpoints.get_route(runtime, thread_id)

  @doc "List durable thread routes for an agent endpoint."
  def list_agent_thread_routes(runtime, endpoint_id, opts \\ [])
      when is_binary(endpoint_id) and is_list(opts),
      do: AgentEndpoints.list_routes(runtime, endpoint_id, opts)

  @doc "Update opaque Jidoka correlation references for a thread route."
  def put_agent_thread_route_correlations(runtime, thread_id, correlations)
      when is_binary(thread_id) and is_map(correlations),
      do: AgentEndpoints.put_route_correlations(runtime, thread_id, correlations)

  @doc "Revoke a durable agent endpoint route."
  def revoke_agent_thread_route(runtime, thread_id, opts \\ [])
      when is_binary(thread_id) and is_list(opts),
      do: AgentEndpoints.revoke_route(runtime, thread_id, opts)

  @doc "Resolve an available endpoint, membership, and route for a thread."
  def resolve_agent_thread_endpoint(runtime, thread_id) when is_binary(thread_id),
    do: AgentEndpoints.resolve_target(runtime, thread_id)

  @doc "Create or replace the canonical principal for an existing participant."
  def create_principal(runtime, attrs) when is_map(attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    principal = Principal.new(attrs)
    Identity.persist_principal(persistence, persistence_state, principal)
  end

  @doc "Persist an already-constructed canonical principal."
  def save_principal(runtime, %Principal{} = principal) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    principal = principal |> Map.from_struct() |> Principal.new()
    Identity.persist_principal(persistence, persistence_state, principal)
  end

  @doc "Get a canonical principal by ID."
  def get_principal(runtime, principal_id) when is_binary(principal_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    case Identity.get_principal(persistence, persistence_state, principal_id) do
      {:error, :unsupported} ->
        with {:ok, participant} <- persistence.get_participant(persistence_state, principal_id) do
          {:ok, Principal.from_participant(participant)}
        end

      result ->
        result
    end
  end

  @doc "Get or create the principal projection for a participant."
  def principal_for_participant(runtime, participant_id) when is_binary(participant_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    with {:ok, participant} <- persistence.get_participant(persistence_state, participant_id) do
      Identity.ensure_principal(persistence, persistence_state, participant)
    end
  end

  @doc false
  def resolve_authorship(runtime, participant, channel, bridge_id, external_id, verify_result, opts \\ []) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    Identity.resolve_authorship(
      persistence,
      persistence_state,
      participant,
      channel,
      to_string(bridge_id),
      to_string(external_id),
      verify_result,
      opts
    )
  end

  @doc "Bind one bridge-scoped provider identity to a canonical principal."
  def bind_external_identity(runtime, principal_id, channel, bridge_id, external_id, opts \\ [])
      when is_binary(principal_id) and is_list(opts) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    with {:ok, %Principal{status: :active} = principal} <- get_principal(runtime, principal_id) do
      Identity.bind_external_identity(
        persistence,
        persistence_state,
        principal,
        channel,
        to_string(bridge_id),
        to_string(external_id),
        opts
      )
    else
      {:ok, %Principal{status: status}} -> {:error, {:principal_inactive, status}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Get an external identity binding by its record ID."
  def get_external_identity_binding(runtime, binding_id) when is_binary(binding_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    Identity.get_binding(persistence, persistence_state, binding_id)
  end

  @doc "Get an external identity binding by its complete provider scope."
  def get_external_identity_binding(runtime, channel, bridge_id, external_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    Identity.get_binding(persistence, persistence_state, channel, bridge_id, external_id)
  end

  @doc "List the bridge-scoped provider identities for one principal."
  def list_external_identity_bindings(runtime, principal_id, opts \\ [])
      when is_binary(principal_id) and is_list(opts) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    Identity.list_bindings(persistence, persistence_state, principal_id, opts)
  end

  @doc "Revoke an external identity binding and keep its audit record."
  def revoke_external_identity_binding(runtime, binding_id, opts \\ [])
      when is_binary(binding_id) and is_list(opts) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)

    with {:ok, binding} <- Identity.get_binding(persistence, persistence_state, binding_id) do
      revoked_at = Keyword.get(opts, :revoked_at, DateTime.utc_now())
      metadata_updates = Keyword.get(opts, :metadata, %{})
      metadata_updates = if is_map(metadata_updates), do: metadata_updates, else: %{}
      metadata = Map.merge(binding.metadata, metadata_updates)

      binding
      |> ExternalIdentityBinding.revoke(revoked_at)
      |> Map.put(:metadata, metadata)
      |> then(&Identity.save_binding(persistence, persistence_state, &1))
    end
  end

  @doc "Save a message"
  def save_message(runtime, attrs) when is_map(attrs) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    message = Message.new(attrs)
    persistence.save_message(persistence_state, message)
  end

  @doc "Get a message by ID"
  def get_message(runtime, message_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_message(persistence_state, message_id)
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

  @doc "Record one authorized Jidoka-emitted delegation observation."
  def record_jidoka_delegation_event(instance_module, runtime, attrs, scope) do
    Jido.Messaging.DelegationTransport.record(instance_module, runtime, attrs, scope)
  end

  @doc "Get a Jidoka delegation event within its exact authorization scope."
  def get_jidoka_delegation_event(instance_module, runtime, event_id, scope) do
    Jido.Messaging.DelegationTransport.get(instance_module, runtime, event_id, scope)
  end

  @doc "Get only the authorized canonical messages named by a delegation event."
  def jidoka_delegation_context(instance_module, runtime, event_id, scope) do
    Jido.Messaging.DelegationTransport.context(instance_module, runtime, event_id, scope)
  end

  @doc "Create or update a messaging reference to Jidoka-owned continuity."
  def put_thread_continuity(runtime, attrs) do
    Jido.Messaging.Continuity.put(runtime, attrs)
  end

  @doc "Get a thread continuity link within an authorized history scope."
  def get_thread_continuity(instance_module, runtime, thread_id, scope) do
    Jido.Messaging.Continuity.get(instance_module, runtime, thread_id, scope)
  end

  @doc "Resolve a usable opaque Jidoka continuity reference."
  def resolve_thread_continuity(instance_module, runtime, thread_id, scope) do
    Jido.Messaging.Continuity.resolve(instance_module, runtime, thread_id, scope)
  end

  @doc "Change the availability state of a thread continuity link."
  def set_thread_continuity_status(runtime, thread_id, status, expected_revision, opts \\ []) do
    Jido.Messaging.Continuity.set_status(runtime, thread_id, status, expected_revision, opts)
  end

  @doc "Clear a thread continuity link and keep a durable marker."
  def clear_thread_continuity(runtime, thread_id, expected_revision, opts \\ []) do
    Jido.Messaging.Continuity.clear(runtime, thread_id, expected_revision, opts)
  end

  @doc "Return a scoped canonical transcript and its opaque Jidoka link."
  def jidoka_continuity_context(instance_module, runtime, thread_id, scope, opts \\ []) do
    Jido.Messaging.Continuity.context(instance_module, runtime, thread_id, scope, opts)
  end

  @doc """
  Return participant-scoped canonical history within an explicit room scope.

  The scope must belong to `instance_module`. The persistence query receives
  only the allowed room IDs, so cursors from other rooms return
  `{:error, :cursor_not_found}`.
  """
  def participant_transcript(instance_module, runtime, participant_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(participant_id) and is_list(opts) do
    transcript_read(fn ->
      with :ok <- validate_history_scope(instance_module, scope),
           {persistence, persistence_state} <- Runtime.get_persistence(runtime),
           {:ok, participant} <- persistence.get_participant(persistence_state, participant_id),
           {:ok, messages} <-
             persistence.get_participant_messages(persistence_state, participant_id, scope.room_ids, opts) do
        entries =
          Enum.map(
            messages,
            &build_transcript_entry(
              instance_module,
              persistence,
              persistence_state,
              participant,
              &1
            )
          )

        {:ok, entries}
      end
    end)
  end

  @doc "Record one scoped advisory trust-evidence revision."
  def record_trust_evidence(instance_module, runtime, attrs, scope) do
    Jido.Messaging.TrustEvidenceService.record(instance_module, runtime, attrs, scope)
  end

  @doc "Query advisory trust evidence without ranking or selecting an agent."
  def query_trust_evidence(instance_module, runtime, scope, opts \\ []) do
    Jido.Messaging.TrustEvidenceService.query(instance_module, runtime, scope, opts)
  end

  @doc "Store a safe messaging activity projection from a trusted Jidoka adapter."
  def project_messaging_activity(runtime, attrs) when is_atom(runtime) and is_map(attrs),
    do: ActivityProjection.project(runtime, attrs)

  @doc "Return Jidoka-linked activity for one principal inside explicit room scope."
  def principal_activity(instance_module, runtime, principal_id, scope, opts \\ [])
      when is_atom(instance_module) and is_atom(runtime) and is_binary(principal_id) and is_list(opts),
      do: ActivityProjection.principal_activity(instance_module, runtime, principal_id, scope, opts)

  @doc "Search a configured optional transcript projection."
  def search_transcript(instance_module, query, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(query) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection) do
      context = %{instance_module: instance_module, scope: scope}

      with {:ok, entries} <-
             projection_call(fn -> projection.search(query, context, Keyword.delete(opts, :projection)) end, :search),
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
      entry =
        build_transcript_entry(
          instance_module,
          persistence,
          persistence_state,
          participant,
          message
        )

      context = %{instance_module: instance_module, scope: scope}
      projection_call(fn -> projection.upsert(entry, context, Keyword.delete(opts, :projection)) end, :write)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_transcript_result}
    end
  rescue
    _ -> {:error, :transcript_read_failed}
  catch
    _, _ -> {:error, :transcript_read_failed}
  end

  @doc "Delete one committed canonical message from a configured search projection."
  def delete_transcript_search(instance_module, message_id, room_id, scope, opts \\ [])
      when is_atom(instance_module) and is_binary(message_id) and is_binary(room_id) and is_list(opts) do
    with :ok <- validate_history_scope(instance_module, scope),
         :ok <- validate_history_room(scope, room_id),
         {:ok, projection} <- search_projection(instance_module, opts),
         :ok <- validate_projection(projection) do
      context = %{instance_module: instance_module, scope: scope}
      projection_call(fn -> projection.delete(message_id, context, Keyword.delete(opts, :projection)) end, :write)
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

      projection_call(
        fn -> projection.rebuild(entries, context, Keyword.drop(opts, [:projection, :batch_size])) end,
        :write
      )
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

  @doc "Get a provider message within one canonical room."
  def get_message_by_external_id(runtime, channel, bridge_id, external_id, room_id) do
    {persistence, persistence_state} = Runtime.get_persistence(runtime)
    persistence.get_message_by_external_id(persistence_state, channel, bridge_id, external_id, room_id)
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
    if target == :agent do
      Jido.Messaging.AgentDirectory.lookup_from_directory(runtime, query, opts)
    else
      {persistence, persistence_state} = Runtime.get_persistence(runtime)
      persistence.directory_lookup(persistence_state, target, query, opts)
    end
  end

  @doc "Search directory entries."
  def directory_search(runtime, target, query, opts \\ [])
      when is_atom(target) and is_map(query) and is_list(opts) do
    if target == :agent do
      Jido.Messaging.AgentDirectory.search_from_directory(runtime, query, opts)
    else
      {persistence, persistence_state} = Runtime.get_persistence(runtime)
      persistence.directory_search(persistence_state, target, query, opts)
    end
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

  @doc "Register a legacy in-memory agent handler with a room."
  def register_agent(instance_module, room_id, agent_spec, opts \\ [])
      when is_atom(instance_module) and is_binary(room_id) and is_map(agent_spec) and is_list(opts) do
    normalized_spec = normalize_agent_spec(agent_spec, opts)

    with {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, threads} <- assignment_threads(runtime_name(instance_module), room_id),
         {:ok, registered_spec} <- room_server_register_agent(room_server, normalized_spec),
         :ok <- restore_agent_assignments(instance_module, room_id, room_server, registered_spec, threads) do
      {:ok, registered_spec}
    end
  end

  @doc "Unregister an agent from a room."
  def unregister_agent(instance_module, room_id, agent_id)
      when is_atom(instance_module) and is_binary(room_id) and is_binary(agent_id) do
    runtime = runtime_name(instance_module)

    with {:ok, room_server} <- ensure_room_server(instance_module, room_id),
         {:ok, thread_ids} <- assigned_thread_ids_for_agent(runtime, room_server, room_id, agent_id) do
      thread_ids
      |> Enum.reduce_while(:ok, fn thread_id, :ok ->
        case unassign_thread(instance_module, room_id, thread_id) do
          {:ok, _thread} ->
            {:cont, :ok}

          {:error, :not_found} ->
            with :ok <- stop_thread_runner(instance_module, room_id, thread_id, agent_id),
                 :ok <- room_server_unassign_thread(room_server, thread_id),
                 do: {:cont, :ok},
                 else: ({:error, reason} -> {:halt, {:error, reason}})

          {:error, reason} ->
            {:halt, {:error, reason}}
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
              _ = persist_thread_assignment(runtime, thread)
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

  @doc false
  def restore_agent_runners(instance_module) when is_atom(instance_module) do
    runtime = runtime_name(instance_module)
    room_supervisor = Module.concat(instance_module, :RoomSupervisor)

    if is_nil(Process.whereis(runtime)) or is_nil(Process.whereis(room_supervisor)) do
      {:error, :runtime_unavailable}
    else
      RoomSupervisor.list_rooms(instance_module)
      |> Enum.reduce_while(:ok, fn {room_id, room_server}, :ok ->
        with {:ok, agents} <- room_server_list_agents(room_server),
             {:ok, threads} <- assignment_threads(runtime, room_id),
             :ok <- restore_registered_threads(instance_module, room_id, room_server, agents, threads) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
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

    with true <- channel in [:telegram, :discord],
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

  defp normalize_id(nil), do: nil
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

  defp restore_registered_threads(instance_module, room_id, room_server, agents, threads) do
    Enum.reduce_while(agents, :ok, fn agent_spec, :ok ->
      case restore_agent_assignments(instance_module, room_id, room_server, agent_spec, threads) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp restore_agent_assignments(instance_module, room_id, room_server, agent_spec, threads) do
    agent_id = agent_spec.agent_id

    Enum.reduce_while(threads, :ok, fn
      %Thread{id: thread_id, assigned_agent_id: ^agent_id}, :ok ->
        with {:ok, assignment} <- room_server_thread_assignment_result(room_server, thread_id) do
          if assignment in [nil, agent_id] do
            with :ok <- room_server_assign_thread(room_server, thread_id, agent_id),
                 {:ok, _pid} <- ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec),
                 do: {:cont, :ok},
                 else: ({:error, _} = error -> {:halt, error})
          else
            {:cont, :ok}
          end
        else
          {:error, _} = error -> {:halt, error}
        end

      _thread, :ok ->
        {:cont, :ok}
    end)
  end

  defp assigned_thread_ids_for_agent(runtime, room_server, room_id, agent_id) do
    with {:ok, assignments} <- room_server_list_thread_assignments(room_server),
         {:ok, threads} <- assignment_threads(runtime, room_id) do
      in_memory = for {thread_id, ^agent_id} <- assignments, do: thread_id
      persisted = for %Thread{id: thread_id, assigned_agent_id: ^agent_id} <- threads, do: thread_id
      {:ok, Enum.uniq(in_memory ++ persisted)}
    end
  end

  defp assignment_threads(runtime, room_id) do
    case list_threads(runtime, room_id) do
      {:ok, threads} when is_list(threads) ->
        if Enum.all?(threads, fn
             %Thread{id: id, room_id: ^room_id, assigned_agent_id: agent} ->
               is_binary(id) and id != "" and (is_nil(agent) or is_binary(agent))

             _ ->
               false
           end) and length(threads) == length(Enum.uniq_by(threads, & &1.id)),
           do: {:ok, threads},
           else: {:error, :persistence_failed}

      {:error, _} = error ->
        error

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
  end

  defp ensure_agent_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
    start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec)
  end

  defp persist_thread_assignment(runtime, %Thread{} = thread) do
    case save_thread_struct(runtime, thread) do
      {:ok, %Thread{id: id, room_id: room_id} = saved} when id == thread.id and room_id == thread.room_id ->
        {:ok, saved}

      {:error, _} = error ->
        error

      _ ->
        {:error, :persistence_failed}
    end
  rescue
    _ -> {:error, :persistence_failed}
  catch
    _, _ -> {:error, :persistence_failed}
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
    with {:ok, persisted_thread} <- persist_thread_assignment(runtime, updated_thread),
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
    with {:ok, _thread} <- persist_thread_assignment(runtime, original_thread),
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
    case start_thread_runner(instance_module, room_id, thread_id, agent_id, agent_spec) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp build_transcript_entry(
         instance_module,
         persistence,
         persistence_state,
         participant,
         message
       ) do
    authorship = Identity.authorship_for_message(message, participant)
    binding = Identity.binding_for_message(persistence, persistence_state, message, authorship)

    Jido.Messaging.TranscriptEntry.new(instance_module, participant, message,
      authorship: authorship,
      external_identity_binding: binding
    )
  end

  defp validate_history_scope(
         instance_module,
         %Jido.Messaging.HistoryScope{instance_module: instance_module, room_ids: room_ids, metadata: metadata}
       ) do
    case Jido.Messaging.HistoryScope.new(instance_module, room_ids, metadata) do
      {:ok, _scope} -> :ok
      {:error, _} = error -> error
    end
  end

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

  defp projection_call(callback, operation) do
    case {operation, callback.()} do
      {:search, {:ok, entries}} -> {:ok, entries}
      {:write, :ok} -> :ok
      {_, {:error, _} = error} -> error
      _ -> {:error, :invalid_search_projection_result}
    end
  rescue
    _ -> {:error, :search_projection_failed}
  catch
    _, _ -> {:error, :search_projection_failed}
  end

  defp transcript_read(callback) do
    case callback.() do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      {:error, _} = error -> error
      _ -> {:error, :invalid_transcript_result}
    end
  rescue
    _ -> {:error, :transcript_read_failed}
  catch
    _, _ -> {:error, :transcript_read_failed}
  end

  defp validate_projection_results(entries, instance_module, scope) when is_list(entries) do
    allowed_rooms = MapSet.new(scope.room_ids)
    {persistence, state} = Runtime.get_persistence(instance_module.__jido_messaging__(:runtime))

    if Enum.all?(entries, fn
         %Jido.Messaging.TranscriptEntry{instance_module: ^instance_module, room_id: room_id} = entry ->
           MapSet.member?(allowed_rooms, room_id) and
             projection_entry_consistent?(entry, instance_module, persistence, state)

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

  defp projection_entry_consistent?(%Jido.Messaging.TranscriptEntry{} = entry, instance, persistence, state) do
    with {:ok, message} <- persistence.get_message(state, entry.canonical_message_id),
         {:ok, participant} <- persistence.get_participant(state, message.sender_id) do
      canonical = build_transcript_entry(instance, persistence, state, participant, message)

      Map.drop(entry, [:authorship]) == Map.drop(canonical, [:authorship]) and
        projection_authorship_consistent?(entry.authorship, canonical.authorship, message)
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp projection_authorship_consistent?(
         %Jido.Messaging.Authorship{} = entry,
         %Jido.Messaging.Authorship{} = canonical,
         message
       ) do
    stored_authorship = Map.get(message.metadata, :authorship) || Map.get(message.metadata, "authorship")

    if is_nil(message.inserted_at) and is_nil(message.updated_at) and is_nil(stored_authorship),
      do: Map.delete(entry, :asserted_at) == Map.delete(canonical, :asserted_at),
      else: entry == canonical
  end

  defp projection_authorship_consistent?(_entry, _canonical, _message), do: false

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
end
