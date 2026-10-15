defmodule Jido.Messaging.Persistence.Contracts.ProviderBindings do
  @moduledoc """
  Storage contract for provider bindings.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.Message
  alias Jido.Chat.Participant
  alias Jido.Chat.Room

  @type state :: Jido.Messaging.Persistence.state()
  @type room_id :: Jido.Messaging.Persistence.room_id()
  @type participant_id :: Jido.Messaging.Persistence.participant_id()
  @type message_id :: Jido.Messaging.Persistence.message_id()
  @type channel :: Jido.Messaging.Persistence.channel()
  @type bridge_id :: Jido.Messaging.Persistence.bridge_id()
  @type external_id :: Jido.Messaging.Persistence.external_id()

  @callback get_or_create_room_by_external_binding(
              state,
              channel,
              bridge_id,
              external_id,
              attrs :: map()
            ) :: {:ok, Room.t()}

  @callback get_or_create_participant_by_external_id(
              state,
              channel,
              external_id,
              attrs :: map()
            ) :: {:ok, Participant.t()}

  @callback get_or_create_participant_by_external_binding(
              state,
              channel,
              bridge_id,
              external_id,
              attrs :: map()
            ) :: {:ok, Participant.t()}

  @callback bind_participant_external_id(state, participant_id, channel, bridge_id, external_id) ::
              :ok | {:error, :not_found | {:external_identity_conflict, participant_id}}

  @callback get_message_by_external_id(state, channel, bridge_id, external_id) ::
              {:ok, Message.t()} | {:error, :not_found}

  @callback get_message_by_external_id(state, channel, bridge_id, external_id, room_id) ::
              {:ok, Message.t()} | {:error, :not_found}

  @callback update_message_external_id(state, message_id, external_id) ::
              {:ok, Message.t()} | {:error, term()}

  @callback get_room_by_external_binding(state, channel, bridge_id, external_id) ::
              {:ok, Room.t()} | {:error, :not_found}

  @callback create_room_binding(
              state,
              room_id,
              channel,
              bridge_id,
              external_id,
              attrs :: map()
            ) :: {:ok, Jido.Messaging.RoomBinding.t()} | {:error, term()}

  @callback list_room_bindings(state, room_id) :: {:ok, [Jido.Messaging.RoomBinding.t()]}

  @callback delete_room_binding(state, binding_id :: String.t()) :: :ok | {:error, term()}
end
