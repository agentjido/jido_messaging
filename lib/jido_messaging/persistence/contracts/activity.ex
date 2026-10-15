defmodule Jido.Messaging.Persistence.Contracts.Activity do
  @moduledoc """
  Storage contract for activity.

  Each callback is required when an adapter declares this behaviour.
  The aggregate `Jido.Messaging.Persistence` contract remains available for
  existing adapters. See `docs/storage-contracts.md` for feature support and tests.
  """

  alias Jido.Messaging.MessagingActivityEntry

  @type state :: Jido.Messaging.Persistence.state()
  @type room_id :: Jido.Messaging.Persistence.room_id()
  @type participant_id :: Jido.Messaging.Persistence.participant_id()

  @callback save_messaging_activity(state, MessagingActivityEntry.t()) ::
              {:ok, MessagingActivityEntry.t()} | {:error, term()}

  @callback get_messaging_activity(state, String.t()) ::
              {:ok, MessagingActivityEntry.t()} | {:error, :not_found}

  @callback get_principal_activity(state, participant_id(), room_ids :: [room_id()], keyword()) ::
              {:ok, [MessagingActivityEntry.t()]} | {:error, term()}
end
