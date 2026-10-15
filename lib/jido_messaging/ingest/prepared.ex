defmodule Jido.Messaging.Ingest.Prepared do
  @moduledoc false

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{Message, MsgContext, Thread}

  # Transient ingest state. Only its message is passed to canonical storage.
  @enforce_keys [
    :instance,
    :adapter,
    :channel_type,
    :bridge_id,
    :external_room_id,
    :incoming,
    :opts,
    :room,
    :room_server,
    :participant,
    :msg_context,
    :message
  ]
  defstruct @enforce_keys ++ [:thread]

  @type t :: %__MODULE__{
          instance: module(),
          adapter: module(),
          channel_type: atom(),
          bridge_id: String.t(),
          external_room_id: term(),
          incoming: map(),
          opts: keyword(),
          room: Room.t(),
          room_server: pid(),
          participant: Participant.t(),
          msg_context: MsgContext.t(),
          thread: Thread.t() | nil,
          message: Message.t()
        }
end
