defmodule Jido.Messaging.Signal.ParticipantJoined do
  @moduledoc """
  Typed fact definition for `jido.messaging.room.participant_joined`.

  Data uses the protocol version 1 string-key schema. Canonical room subject; this fact describes committed runtime state, not provider membership evidence.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.room.participant_joined",
    dataschema: "urn:jido:messaging:schema:room_participant_joined:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "participant_id" => Zoi.string() |> Zoi.min(1),
          "reason" => Zoi.string()
        },
        unrecognized_keys: :error
      )
end
