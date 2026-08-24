defmodule Jido.Messaging.TranscriptEntry do
  @moduledoc """
  Canonical transcript result with provider identity fields.
  """

  alias Jido.Chat.Participant
  alias Jido.Messaging.{Authorship, ExternalIdentityBinding, Identity, Message}

  @enforce_keys [
    :instance_module,
    :canonical_message_id,
    :canonical_participant_id,
    :principal_id,
    :room_id,
    :inserted_at,
    :message
  ]
  defstruct [
    :instance_module,
    :canonical_message_id,
    :canonical_participant_id,
    :principal_id,
    :room_id,
    :channel,
    :bridge_id,
    :provider_message_id,
    :provider_participant_id,
    :external_identity_binding_id,
    :authorship_assurance,
    :authorship,
    :inserted_at,
    :message
  ]

  @type t :: %__MODULE__{
          instance_module: module(),
          canonical_message_id: String.t(),
          canonical_participant_id: String.t(),
          principal_id: String.t(),
          room_id: String.t(),
          channel: atom() | String.t() | nil,
          bridge_id: String.t() | nil,
          provider_message_id: String.t() | nil,
          provider_participant_id: String.t() | nil,
          external_identity_binding_id: String.t() | nil,
          authorship_assurance: ExternalIdentityBinding.assurance(),
          authorship: Authorship.t(),
          inserted_at: DateTime.t(),
          message: Message.t()
        }

  @doc "Builds a transcript entry from canonical participant and message records."
  @spec new(module(), Participant.t(), Message.t(), keyword()) :: t()
  def new(instance_module, %Participant{} = participant, %Message{} = message, opts \\ [])
      when is_atom(instance_module) and is_list(opts) do
    channel = metadata_value(message.metadata, :channel)
    authorship = Keyword.get(opts, :authorship) || Identity.authorship_for_message(message, participant)
    binding = Keyword.get(opts, :external_identity_binding)

    %__MODULE__{
      instance_module: instance_module,
      canonical_message_id: message.id,
      canonical_participant_id: participant.id,
      principal_id: authorship.principal_id,
      room_id: message.room_id,
      channel: channel,
      bridge_id: metadata_value(message.metadata, :bridge_id),
      provider_message_id: message.external_id,
      provider_participant_id: provider_participant_id(participant, channel, binding),
      external_identity_binding_id: authorship.external_identity_binding_id || binding_id(binding),
      authorship_assurance: authorship.assurance,
      authorship: authorship,
      inserted_at: message.inserted_at,
      message: message
    }
  end

  defp provider_participant_id(_participant, _channel, %ExternalIdentityBinding{} = binding),
    do: binding.external_id

  defp provider_participant_id(_participant, _channel, :ambiguous), do: nil

  defp provider_participant_id(_participant, nil, _binding), do: nil

  defp provider_participant_id(participant, channel, _binding) do
    external_ids = participant.external_ids || %{}
    Map.get(external_ids, channel) || Map.get(external_ids, to_string(channel))
  end

  defp binding_id(%ExternalIdentityBinding{id: id}), do: id
  defp binding_id(_binding), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end
