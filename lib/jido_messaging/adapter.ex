defmodule JidoMessaging.Adapter do
  @moduledoc """
  Behaviour for JidoMessaging storage adapters.

  Adapters provide persistence for rooms, participants, and messages.
  Each adapter instance maintains its own state (e.g., ETS table references)
  to enable multiple isolated messaging instances in the same BEAM.

  ## Implementing an Adapter

      defmodule MyApp.CustomAdapter do
        @behaviour JidoMessaging.Adapter

        @impl true
        def init(opts) do
          # Initialize adapter state
          {:ok, %{}}
        end

        # ... implement other callbacks
      end
  """

  alias JidoMessaging.{Message, Room, Participant}

  @type state :: term()
  @type room_id :: String.t()
  @type participant_id :: String.t()
  @type message_id :: String.t()
  @type channel :: atom()
  @type instance_id :: String.t()
  @type external_id :: String.t()

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
  @callback save_message(state, Message.t()) :: {:ok, Message.t()} | {:error, term()}

  @doc "Get a message by ID"
  @callback get_message(state, message_id) :: {:ok, Message.t()} | {:error, :not_found}

  @doc "Get messages for a room with options (limit, before, after)"
  @callback get_messages(state, room_id, opts :: keyword()) :: {:ok, [Message.t()]}

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
              instance_id,
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
  @callback get_message_by_external_id(state, channel, instance_id, external_id) ::
              {:ok, Message.t()} | {:error, :not_found}

  @doc """
  Update a message's external_id after successful channel delivery.

  Used to record the external platform's message ID after sending.
  """
  @callback update_message_external_id(state, message_id, external_id) ::
              {:ok, Message.t()} | {:error, term()}
end
