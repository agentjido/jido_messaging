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
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"participant_id":{"type":"string","minLength":1},"reason":{"type":"string"}},"required":["room_id","participant_id","reason"],"additionalProperties":false}|
        )
      )
end
