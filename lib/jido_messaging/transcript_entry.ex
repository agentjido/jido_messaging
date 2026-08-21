defmodule Jido.Messaging.TranscriptEntry do
  @moduledoc """
  Canonical transcript result with provider identity fields.
  """

  alias Jido.Chat.Participant
  alias Jido.Messaging.Message

  @enforce_keys [
    :instance_module,
    :canonical_message_id,
    :canonical_participant_id,
    :room_id,
    :inserted_at,
    :message
  ]
  defstruct [
    :instance_module,
    :canonical_message_id,
    :canonical_participant_id,
    :room_id,
    :channel,
    :bridge_id,
    :provider_message_id,
    :provider_participant_id,
    :inserted_at,
    :message
  ]

  @type t :: %__MODULE__{
          instance_module: module(),
          canonical_message_id: String.t(),
          canonical_participant_id: String.t(),
          room_id: String.t(),
          channel: atom() | String.t() | nil,
          bridge_id: String.t() | nil,
          provider_message_id: String.t() | nil,
          provider_participant_id: String.t() | nil,
          inserted_at: DateTime.t(),
          message: Message.t()
        }

  @doc "Builds a transcript entry from canonical participant and message records."
  @spec new(module(), Participant.t(), Message.t()) :: t()
  def new(instance_module, %Participant{} = participant, %Message{} = message) when is_atom(instance_module) do
    channel = metadata_value(message.metadata, :channel)

    %__MODULE__{
      instance_module: instance_module,
      canonical_message_id: message.id,
      canonical_participant_id: participant.id,
      room_id: message.room_id,
      channel: channel,
      bridge_id: metadata_value(message.metadata, :bridge_id),
      provider_message_id: message.external_id,
      provider_participant_id: provider_participant_id(participant, channel),
      inserted_at: message.inserted_at,
      message: message
    }
  end

  defp provider_participant_id(_participant, nil), do: nil

  defp provider_participant_id(participant, channel) do
    external_ids = participant.external_ids || %{}
    Map.get(external_ids, channel) || Map.get(external_ids, to_string(channel))
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end
