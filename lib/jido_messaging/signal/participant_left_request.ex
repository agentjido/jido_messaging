defmodule Jido.Messaging.Signal.ParticipantLeftRequest do
  @moduledoc """
  Typed command definition for `jido.messaging.command.participant_left`.

  Data uses the protocol version 1 string-key schema. Canonical room subject if room_id is present; absent before creation.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.participant_left",
    dataschema: "urn:jido:messaging:schema:command_participant_left:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"participant_id":{"type":"string","minLength":1},"reason":{"type":"string"}},"required":["request_id","room_id","participant_id"],"additionalProperties":false}|
        )
      )
end
