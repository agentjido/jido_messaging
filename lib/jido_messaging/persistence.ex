defmodule Jido.Messaging.Persistence do
  @moduledoc """
  Behaviour for Jido.Messaging storage adapters.

  Adapters provide persistence for rooms, participants, threads, and messages.
  Each adapter instance maintains its own state (e.g., ETS table references)
  to enable multiple isolated messaging instances in the same BEAM.

  Use `Jido.Messaging.Persistence.Postgres` for production. Use
  `Jido.Messaging.Persistence.SQLite` for demos, local development, and tests.
  Use `Jido.Messaging.Persistence.ETS` for explicit in-memory operation.

  Capabilities describe current guarantees. `:durable` means canonical records
  survive a runtime restart. `:transactions` means the adapter can commit a
  group of persistence calls atomically. `:concurrent_writers` means multiple
  pools or nodes can write safely. These capabilities do not imply RFC 0001's
  broader `:transactional_delivery` guarantee.

  ## Implementing an Adapter

      defmodule MyApp.CustomAdapter do
        @behaviour Jido.Messaging.Persistence

        @impl true
        def init(opts) do
          # Initialize adapter state
          {:ok, %{}}
        end

        # ... implement other callbacks
      end
  """

  alias Jido.Chat.{Participant, Room}

  alias Jido.Messaging.{
    AgentDirectoryProjection,
    AgentMessagingEndpoint,
    AgentThreadRoute,
    BridgeConfig,
    ExternalIdentityBinding,
    Grant,
    IdentityCredential,
    IngressSubscription,
    InvocationPolicy,
    JidokaDelegationEvent,
    Membership,
    MessagingActivityEntry,
    Message,
    Principal,
    RoomMembership,
    RoutingPolicy,
    Thread,
    ThreadContinuityLink,
    TrustEvidence
  }

  @type state :: term()
  @type room_id :: String.t()
  @type participant_id :: String.t()
  @type message_id :: String.t()
  @type channel :: atom()
  @type bridge_id :: String.t()
  @type external_id :: String.t()
  @type directory_target :: :participant | :room | :agent
  @type directory_query :: map()
  @type onboarding_id :: String.t()
  @type onboarding_flow :: map()
  @type capability ::
          :memory | :durable | :transactions | :concurrent_writers | :transactional_delivery
  @type transaction_result(value) :: {:ok, value} | {:error, term()}

  # Initialization
  @doc "Initialize the adapter with options. Returns adapter state."
  @callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}

  @doc "Report storage guarantees that the initialized adapter provides."
  @callback capabilities(state) :: [capability]

  @doc "Check the adapter connection and required schema."
  @callback health_check(state) :: :ok | {:error, term()}

  @doc "Run adapter operations in one storage transaction."
  @callback transaction(state, (state -> transaction_result(value))) :: transaction_result(value)
            when value: term()

  @doc "Release resources that the adapter owns."
  @callback close(state) :: :ok

  # Room operations
  @doc "Save a room (insert or update)"
  @callback save_room(state, Room.t()) :: {:ok, Room.t()} | {:error, term()}

  @doc "Get a room by ID"
  @callback get_room(state, room_id) :: {:ok, Room.t()} | {:error, :not_found}

  @doc "Delete a room by ID"
  @callback delete_room(state, room_id) :: :ok | {:error, term()}

  @doc "List rooms with optional filters"
  @callback list_rooms(state, opts :: keyword()) :: {:ok, [Room.t()]}

  # Participant operations
  @doc "Save a participant (insert or update)"
  @callback save_participant(state, Participant.t()) :: {:ok, Participant.t()} | {:error, term()}

  @doc "Get a participant by ID"
  @callback get_participant(state, participant_id) :: {:ok, Participant.t()} | {:error, :not_found}

  @doc "Delete a participant by ID"
  @callback delete_participant(state, participant_id) :: :ok | {:error, term()}

  # Canonical identity operations
  @doc "Persist a canonical principal."
  @callback save_principal(state, Principal.t()) :: {:ok, Principal.t()} | {:error, term()}

  @doc "Get a canonical principal by ID."
  @callback get_principal(state, String.t()) :: {:ok, Principal.t()} | {:error, :not_found}

  @doc "Persist one bridge-scoped external identity binding."
  @callback save_external_identity_binding(state, ExternalIdentityBinding.t()) ::
              {:ok, ExternalIdentityBinding.t()}
              | {:error, :not_found | :external_identity_revoked | {:external_identity_conflict, String.t()}}

  @doc "Get an external identity binding by its stable record ID."
  @callback get_external_identity_binding(state, String.t()) ::
              {:ok, ExternalIdentityBinding.t()} | {:error, :not_found}

  @doc "Get an external identity binding by its complete provider scope."
  @callback get_external_identity_binding(state, channel, bridge_id, external_id) ::
              {:ok, ExternalIdentityBinding.t()} | {:error, :not_found}

  @doc "List the external identity bindings for one principal."
  @callback list_external_identity_bindings(state, String.t(), keyword()) ::
              {:ok, [ExternalIdentityBinding.t()]} | {:error, term()}

  # Message operations
  @doc "Save a message"
  @callback save_message(state, Message.t()) :: {:ok, Message.t()} | {:error, term()}

  @doc "Get a message by ID"
  @callback get_message(state, message_id) :: {:ok, Message.t()} | {:error, :not_found}

  @doc """
  Get messages for a room with `:limit`, `:before`, and `:after` options.

  Cursor values are message IDs. A cursor must identify a message in the same
  room and optional thread scope. Adapters return `{:error, :cursor_not_found}`
  for a missing or stale cursor and `{:error, :invalid_cursor_options}` when
  both cursor directions are present.
  """
  @callback get_messages(state, room_id, opts :: keyword()) ::
              {:ok, [Message.t()]} | {:error, :cursor_not_found | :invalid_cursor_options}

  @doc "Delete a message by ID"
  @callback delete_message(state, message_id) :: :ok | {:error, term()}

  @doc "Get messages sent by one canonical participant within explicit room scope"
  @callback get_participant_messages(
              state,
              participant_id,
              room_ids :: [room_id],
              opts :: keyword()
            ) :: {:ok, [Message.t()]} | {:error, term()}

  # Advisory trust evidence

  @doc "Persist one immutable trust-evidence revision."
  @callback save_trust_evidence(state, TrustEvidence.t()) ::
              {:ok, TrustEvidence.t()} | {:error, term()}

  @doc "List trust evidence for one subject in one exact room."
  @callback list_trust_evidence(state, participant_id(), room_id(), keyword()) ::
              {:ok, [TrustEvidence.t()]} | {:error, term()}

  @doc "Atomically add a provider-confirmed read receipt to a message"
  @callback mark_message_read(state, message_id, participant_id, receipt :: map()) ::
              {:ok, Message.t(), :updated | :unchanged} | {:error, term()}

  # Thread operations
  @doc "Save a thread"
  @callback save_thread(state, Thread.t()) :: {:ok, Thread.t()} | {:error, term()}

  @doc "Get a thread by ID"
  @callback get_thread(state, String.t()) :: {:ok, Thread.t()} | {:error, :not_found}

  @doc "Get a thread by room and external thread ID"
  @callback get_thread_by_external_id(state, room_id(), String.t()) ::
              {:ok, Thread.t()} | {:error, :not_found}

  @doc "Get a thread by root message ID"
  @callback get_thread_by_root_message(state, room_id(), message_id()) ::
              {:ok, Thread.t()} | {:error, :not_found}

  @doc "List threads for a room"
  @callback list_threads(state, room_id(), opts :: keyword()) :: {:ok, [Thread.t()]}

  # Jidoka delegation transport records

  @doc "Persist an immutable Jidoka delegation transport record."
  @callback save_jidoka_delegation_event(state, JidokaDelegationEvent.t()) ::
              {:ok, JidokaDelegationEvent.t()} | {:error, term()}

  @doc "Fetch a Jidoka delegation transport record by ID."
  @callback get_jidoka_delegation_event(state, String.t()) ::
              {:ok, JidokaDelegationEvent.t()} | {:error, :not_found | term()}
  # Jidoka continuity correlation

  @doc "Persist a messaging thread link to Jidoka-owned continuity state."
  @callback save_thread_continuity_link(state, ThreadContinuityLink.t()) ::
              {:ok, ThreadContinuityLink.t()} | {:error, term()}

  @doc "Fetch a Jidoka continuity link by messaging thread ID."
  @callback get_thread_continuity_link(state, String.t()) ::
              {:ok, ThreadContinuityLink.t()} | {:error, :not_found | term()}
  # Principal authorization operations
  @doc "Persist a revisioned principal room membership."
  @callback save_membership(state, Membership.t()) ::
              {:ok, Membership.t()} | {:error, term()}

  @doc "Get a principal membership by record ID."
  @callback get_membership(state, String.t()) ::
              {:ok, Membership.t()} | {:error, :not_found}

  @doc "Get a principal membership by canonical room and principal."
  @callback get_membership_by_scope(state, room_id(), participant_id()) ::
              {:ok, Membership.t()} | {:error, :not_found}

  @doc "List principal memberships for a canonical room."
  @callback list_memberships(state, room_id(), keyword()) :: {:ok, [Membership.t()]}

  @doc "Persist a revisioned principal messaging grant."
  @callback save_principal_grant(state, Grant.t()) :: {:ok, Grant.t()} | {:error, term()}

  @doc "Get a principal messaging grant by record ID."
  @callback get_principal_grant(state, String.t()) :: {:ok, Grant.t()} | {:error, :not_found}

  @doc "List messaging grants for a canonical principal."
  @callback list_principal_grants(state, participant_id(), keyword()) :: {:ok, [Grant.t()]}

  @doc "Persist a revisioned agent invocation policy."
  @callback save_invocation_policy(state, InvocationPolicy.t()) ::
              {:ok, InvocationPolicy.t()} | {:error, term()}

  @doc "Get an agent invocation policy by record ID."
  @callback get_invocation_policy(state, String.t()) ::
              {:ok, InvocationPolicy.t()} | {:error, :not_found}

  @doc "Get an invocation policy by target principal and stable scope key."
  @callback get_invocation_policy_by_scope(state, participant_id(), String.t()) ::
              {:ok, InvocationPolicy.t()} | {:error, :not_found}

  @doc "List invocation policies for an agent principal."
  @callback list_invocation_policies(state, participant_id(), keyword()) ::
              {:ok, [InvocationPolicy.t()]}
  # Agent messaging endpoint operations
  @doc "Persist a Jidoka agent messaging endpoint."
  @callback save_agent_messaging_endpoint(state, AgentMessagingEndpoint.t()) ::
              {:ok, AgentMessagingEndpoint.t()} | {:error, term()}

  @doc "Get an agent messaging endpoint by record ID."
  @callback get_agent_messaging_endpoint(state, String.t()) ::
              {:ok, AgentMessagingEndpoint.t()} | {:error, :not_found}

  @doc "Get an agent messaging endpoint by opaque Jidoka agent ID."
  @callback get_agent_messaging_endpoint_by_ref(state, String.t()) ::
              {:ok, AgentMessagingEndpoint.t()} | {:error, :not_found}

  @doc "List agent messaging endpoints with optional filters."
  @callback list_agent_messaging_endpoints(state, keyword()) ::
              {:ok, [AgentMessagingEndpoint.t()]}

  @doc "Persist a room membership for an agent endpoint."
  @callback save_room_membership(state, RoomMembership.t()) ::
              {:ok, RoomMembership.t()} | {:error, term()}

  @doc "Get a room membership by record ID."
  @callback get_room_membership(state, String.t()) ::
              {:ok, RoomMembership.t()} | {:error, :not_found}

  @doc "Get a room membership by room and endpoint."
  @callback get_room_membership(state, String.t(), String.t()) ::
              {:ok, RoomMembership.t()} | {:error, :not_found}

  @doc "List room memberships for a room."
  @callback list_room_memberships(state, String.t(), keyword()) ::
              {:ok, [RoomMembership.t()]}

  @doc "Persist a thread route to an agent endpoint."
  @callback save_agent_thread_route(state, AgentThreadRoute.t()) ::
              {:ok, AgentThreadRoute.t()} | {:error, term()}

  @doc "Get an agent endpoint route by thread ID."
  @callback get_agent_thread_route(state, String.t()) ::
              {:ok, AgentThreadRoute.t()} | {:error, :not_found}

  @doc "List thread routes for an agent endpoint."
  @callback list_agent_thread_routes(state, String.t(), keyword()) ::
              {:ok, [AgentThreadRoute.t()]}

  # External ID resolution (for channel mapping)
  @doc """
  Get or create a room by external binding.

  Used when receiving messages from external channels to map external
  chat IDs to internal room IDs.
  """
  @callback get_or_create_room_by_external_binding(
              state,
              channel,
              bridge_id,
              external_id,
              attrs :: map()
            ) :: {:ok, Room.t()}

  @doc """
  Get or create a participant by external ID.

  Used when receiving messages from external channels to map external
  user IDs to internal participant IDs.
  """
  @callback get_or_create_participant_by_external_id(
              state,
              channel,
              external_id,
              attrs :: map()
            ) :: {:ok, Participant.t()}

  @doc """
  Get or create a participant from a bridge-scoped provider identity.

  The bridge ID is the provider tenant or installation scope. Adapters that do
  not implement this callback use the legacy channel-scoped callback.
  """
  @callback get_or_create_participant_by_external_binding(
              state,
              channel,
              bridge_id,
              external_id,
              attrs :: map()
            ) :: {:ok, Participant.t()}

  @doc "Bind a bridge-scoped provider identity to an existing participant."
  @callback bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) ::
              :ok | {:error, :not_found | {:external_identity_conflict, participant_id}}

  # Message external ID operations (for reply/quote mapping)
  @doc """
  Get a message by its external ID within a channel/instance context.

  Used for resolving reply_to references from external platforms.
  """
  @callback get_message_by_external_id(state, channel, bridge_id, external_id) ::
              {:ok, Message.t()} | {:error, :not_found}

  @doc """
  Update a message's external_id after successful channel delivery.

  Used to record the external platform's message ID after sending.
  """
  @callback update_message_external_id(state, message_id, external_id) ::
              {:ok, Message.t()} | {:error, term()}

  # Room binding operations

  @doc """
  Get a room by its external binding.

  Returns the room if a binding exists, otherwise :not_found.
  """
  @callback get_room_by_external_binding(state, channel, bridge_id, external_id) ::
              {:ok, Room.t()} | {:error, :not_found}

  @doc """
  Create a binding between an internal room and an external platform room.
  """
  @callback create_room_binding(
              state,
              room_id,
              channel,
              bridge_id,
              external_id,
              attrs :: map()
            ) :: {:ok, Jido.Messaging.RoomBinding.t()} | {:error, term()}

  @doc """
  List all bindings for a room.
  """
  @callback list_room_bindings(state, room_id) :: {:ok, [Jido.Messaging.RoomBinding.t()]}

  @doc """
  Delete a room binding by ID.
  """
  @callback delete_room_binding(state, binding_id :: String.t()) :: :ok | {:error, term()}

  # Directory operations

  @doc """
  Lookup a single directory entry by target and query.

  Returns `{:error, {:ambiguous, matches}}` when multiple entries satisfy the query.
  """
  @callback directory_lookup(state, directory_target(), directory_query(), opts :: keyword()) ::
              {:ok, map()} | {:error, :not_found | {:ambiguous, [map()]} | term()}

  @doc "Search directory entries by target and query."
  @callback directory_search(state, directory_target(), directory_query(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Save a revisioned safe Jidoka agent directory projection."
  @callback save_agent_directory_projection(state, AgentDirectoryProjection.t()) ::
              {:ok, AgentDirectoryProjection.t()} | {:error, term()}

  @doc "Get an agent directory projection by its deterministic ID."
  @callback get_agent_directory_projection(state, String.t()) ::
              {:ok, AgentDirectoryProjection.t()} | {:error, :not_found | term()}

  @doc "List agent directory projections for scoped filtering."
  @callback list_agent_directory_projections(state, opts :: keyword()) ::
              {:ok, [AgentDirectoryProjection.t()]} | {:error, term()}

  # Onboarding operations

  @doc "Persist onboarding flow state."
  @callback save_onboarding(state, onboarding_flow()) :: {:ok, onboarding_flow()} | {:error, term()}

  @doc "Fetch onboarding flow state by onboarding ID."
  @callback get_onboarding(state, onboarding_id()) :: {:ok, onboarding_flow()} | {:error, :not_found}

  # Bridge/routing control-plane persistence

  @doc "Persist bridge config."
  @callback save_bridge_config(state, BridgeConfig.t()) :: {:ok, BridgeConfig.t()} | {:error, term()}

  @doc "Fetch bridge config by id."
  @callback get_bridge_config(state, String.t()) :: {:ok, BridgeConfig.t()} | {:error, :not_found}

  @doc "List bridge configs with optional filters."
  @callback list_bridge_configs(state, keyword()) :: {:ok, [BridgeConfig.t()]}

  @doc "Delete bridge config."
  @callback delete_bridge_config(state, String.t()) :: :ok | {:error, :not_found}

  @doc "Persist normalized ingress subscription metadata."
  @callback save_ingress_subscription(state, IngressSubscription.t()) ::
              {:ok, IngressSubscription.t()} | {:error, term()}

  @doc "List stored ingress subscription metadata for a bridge."
  @callback list_ingress_subscriptions(state, bridge_id(), keyword()) :: {:ok, [IngressSubscription.t()]}

  @doc "Delete stored ingress subscription metadata."
  @callback delete_ingress_subscription(state, bridge_id(), String.t()) :: :ok | {:error, :not_found}

  # Optional messaging activity projection operations

  @doc "Persist one safe messaging activity projection revision."
  @callback save_messaging_activity(state, MessagingActivityEntry.t()) ::
              {:ok, MessagingActivityEntry.t()} | {:error, term()}

  @doc "Fetch one messaging activity projection by ID."
  @callback get_messaging_activity(state, String.t()) ::
              {:ok, MessagingActivityEntry.t()} | {:error, :not_found}

  @doc "List projected activity for one principal inside explicit room scope."
  @callback get_principal_activity(state, participant_id(), room_ids :: [room_id()], keyword()) ::
              {:ok, [MessagingActivityEntry.t()]} | {:error, term()}
  # Optional identity credential operations

  @doc "Persist a revisioned controller credential."
  @callback save_identity_credential(state, IdentityCredential.t()) ::
              {:ok, IdentityCredential.t()} | {:error, term()}

  @doc "Fetch a controller credential by ID."
  @callback get_identity_credential(state, String.t()) ::
              {:ok, IdentityCredential.t()} | {:error, :not_found}

  @doc "List controller credentials for one subject principal."
  @callback list_identity_credentials(state, participant_id(), keyword()) ::
              {:ok, [IdentityCredential.t()]} | {:error, term()}

  @doc "Atomically revoke an old credential and insert its rotation replacement."
  @callback rotate_identity_credential(
              state,
              revoked :: IdentityCredential.t(),
              replacement :: IdentityCredential.t()
            ) ::
              {:ok, IdentityCredential.t(), IdentityCredential.t()} | {:error, term()}

  @doc "Consume a hashed proof assertion once until its credential expires."
  @callback consume_identity_assertion(
              state,
              credential_id :: String.t(),
              assertion_key :: String.t(),
              expires_at :: DateTime.t()
            ) :: :ok | {:error, term()}

  @optional_callbacks get_or_create_participant_by_external_binding: 5,
                      bind_participant_external_id: 5,
                      save_membership: 2,
                      get_membership: 2,
                      get_membership_by_scope: 3,
                      list_memberships: 3,
                      save_principal_grant: 2,
                      get_principal_grant: 2,
                      list_principal_grants: 3,
                      save_invocation_policy: 2,
                      get_invocation_policy: 2,
                      get_invocation_policy_by_scope: 3,
                      list_invocation_policies: 3,
                      save_agent_messaging_endpoint: 2,
                      get_agent_messaging_endpoint: 2,
                      get_agent_messaging_endpoint_by_ref: 2,
                      list_agent_messaging_endpoints: 2,
                      save_room_membership: 2,
                      get_room_membership: 2,
                      get_room_membership: 3,
                      list_room_memberships: 3,
                      save_agent_thread_route: 2,
                      get_agent_thread_route: 2,
                      list_agent_thread_routes: 3,
                      save_principal: 2,
                      get_principal: 2,
                      save_external_identity_binding: 2,
                      get_external_identity_binding: 2,
                      get_external_identity_binding: 4,
                      list_external_identity_bindings: 3,
                      save_ingress_subscription: 2,
                      list_ingress_subscriptions: 3,
                      delete_ingress_subscription: 3,
                      mark_message_read: 4,
                      save_trust_evidence: 2,
                      list_trust_evidence: 4,
                      save_jidoka_delegation_event: 2,
                      get_jidoka_delegation_event: 2,
                      save_thread_continuity_link: 2,
                      get_thread_continuity_link: 2,
                      save_agent_directory_projection: 2,
                      get_agent_directory_projection: 2,
                      list_agent_directory_projections: 2,
                      save_messaging_activity: 2,
                      get_messaging_activity: 2,
                      get_principal_activity: 4,
                      save_identity_credential: 2,
                      get_identity_credential: 2,
                      list_identity_credentials: 3,
                      rotate_identity_credential: 3,
                      consume_identity_assertion: 4,
                      capabilities: 1,
                      health_check: 1,
                      transaction: 2,
                      close: 1

  @doc "Persist routing policy."
  @callback save_routing_policy(state, RoutingPolicy.t()) :: {:ok, RoutingPolicy.t()} | {:error, term()}

  @doc "Fetch routing policy by room id."
  @callback get_routing_policy(state, String.t()) :: {:ok, RoutingPolicy.t()} | {:error, :not_found}

  @doc "Delete routing policy by room id."
  @callback delete_routing_policy(state, String.t()) :: :ok | {:error, :not_found}
end
