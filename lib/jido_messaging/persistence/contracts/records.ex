defmodule Jido.Messaging.Persistence.Contracts.Records do
  @moduledoc """
  Storage contract for records.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.Message
  alias Jido.Chat.Participant
  alias Jido.Chat.Room
  alias Jido.Messaging.Thread

  @type state :: Jido.Messaging.Persistence.state()
  @type room_id :: Jido.Messaging.Persistence.room_id()
  @type participant_id :: Jido.Messaging.Persistence.participant_id()
  @type message_id :: Jido.Messaging.Persistence.message_id()
  @type directory_target :: Jido.Messaging.Persistence.directory_target()
  @type directory_query :: Jido.Messaging.Persistence.directory_query()
  @type onboarding_id :: Jido.Messaging.Persistence.onboarding_id()
  @type onboarding_flow :: Jido.Messaging.Persistence.onboarding_flow()

  @callback save_room(state, Room.t()) :: {:ok, Room.t()} | {:error, term()}

  @callback get_room(state, room_id) :: {:ok, Room.t()} | {:error, :not_found}

  @callback delete_room(state, room_id) :: :ok | {:error, term()}

  @callback list_rooms(state, opts :: keyword()) :: {:ok, [Room.t()]}

  @callback save_participant(state, Participant.t()) :: {:ok, Participant.t()} | {:error, term()}

  @callback get_participant(state, participant_id) :: {:ok, Participant.t()} | {:error, :not_found}

  @callback delete_participant(state, participant_id) :: :ok | {:error, term()}

  @callback save_message(state, Message.t()) :: {:ok, Message.t()} | {:error, term()}

  @callback get_message(state, message_id) :: {:ok, Message.t()} | {:error, :not_found}

  @callback get_messages(state, room_id, opts :: keyword()) ::
              {:ok, [Message.t()]} | {:error, :cursor_not_found | :invalid_cursor_options}

  @callback delete_message(state, message_id) :: :ok | {:error, term()}

  @callback get_participant_messages(
              state,
              participant_id,
              room_ids :: [room_id],
              opts :: keyword()
            ) :: {:ok, [Message.t()]} | {:error, term()}

  @callback mark_message_read(state, message_id, participant_id, receipt :: map()) ::
              {:ok, Message.t(), :updated | :unchanged} | {:error, term()}

  @callback save_thread(state, Thread.t()) :: {:ok, Thread.t()} | {:error, term()}

  @callback get_thread(state, String.t()) :: {:ok, Thread.t()} | {:error, :not_found}

  @callback get_thread_by_external_id(state, room_id(), String.t()) ::
              {:ok, Thread.t()} | {:error, :not_found}

  @callback get_thread_by_root_message(state, room_id(), message_id()) ::
              {:ok, Thread.t()} | {:error, :not_found}

  @callback list_threads(state, room_id(), opts :: keyword()) :: {:ok, [Thread.t()]}

  @callback directory_lookup(state, directory_target(), directory_query(), opts :: keyword()) ::
              {:ok, map()} | {:error, :not_found | {:ambiguous, [map()]} | term()}

  @callback directory_search(state, directory_target(), directory_query(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @callback save_onboarding(state, onboarding_flow()) :: {:ok, onboarding_flow()} | {:error, term()}

  @callback get_onboarding(state, onboarding_id()) :: {:ok, onboarding_flow()} | {:error, :not_found}
end
