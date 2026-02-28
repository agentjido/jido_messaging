defmodule Jido.Messaging.Persistence do
  @moduledoc """
  Behaviour for Jido.Messaging storage adapters.

  Adapters provide persistence for rooms, participants, and messages.
  Each adapter instance maintains its own state (e.g., ETS table references)
  to enable multiple isolated messaging instances in the same BEAM.

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

  alias Jido.Chat.{LegacyMessage, Participant, Room}
  alias Jido.Messaging.{BridgeConfig, RoutingPolicy}

  @type state :: term()
  @type room_id :: String.t()
  @type participant_id :: String.t()
  @type message_id :: String.t()
  @type channel :: atom()
  @type bridge_id :: String.t()
  @type external_id :: String.t()
  @type directory_target :: :participant | :room
  @type directory_query :: map()
  @type onboarding_id :: String.t()
  @type onboarding_flow :: map()

  # Initialization
  @doc "Initialize the adapter with options. Returns adapter state."
  @callback init(opts :: keyword()) :: {:ok, state} | {:error, term()}

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

  # Message operations
  @doc "Save a message"
  @callback save_message(state, LegacyMessage.t()) :: {:ok, LegacyMessage.t()} | {:error, term()}

  @doc "Get a message by ID"
  @callback get_message(state, message_id) :: {:ok, LegacyMessage.t()} | {:error, :not_found}

  @doc "Get messages for a room with options (limit, before, after)"
  @callback get_messages(state, room_id, opts :: keyword()) :: {:ok, [LegacyMessage.t()]}

  @doc "Delete a message by ID"
  @callback delete_message(state, message_id) :: :ok | {:error, term()}

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

  # Message external ID operations (for reply/quote mapping)
  @doc """
  Get a message by its external ID within a channel/instance context.

  Used for resolving reply_to references from external platforms.
  """
  @callback get_message_by_external_id(state, channel, bridge_id, external_id) ::
              {:ok, LegacyMessage.t()} | {:error, :not_found}

  @doc """
  Update a message's external_id after successful channel delivery.

  Used to record the external platform's message ID after sending.
  """
  @callback update_message_external_id(state, message_id, external_id) ::
              {:ok, LegacyMessage.t()} | {:error, term()}

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

  @doc "Persist routing policy."
  @callback save_routing_policy(state, RoutingPolicy.t()) :: {:ok, RoutingPolicy.t()} | {:error, term()}

  @doc "Fetch routing policy by room id."
  @callback get_routing_policy(state, String.t()) :: {:ok, RoutingPolicy.t()} | {:error, :not_found}

  @doc "Delete routing policy by room id."
  @callback delete_routing_policy(state, String.t()) :: :ok | {:error, :not_found}
end
