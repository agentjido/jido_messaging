defmodule Jido.Messaging.Signal.TypingChanged do
  @moduledoc """
  Typed fact definition for `jido.messaging.participant.typing`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.participant.typing",
    dataschema: "urn:jido:messaging:schema:participant_typing:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"participant_id":{"type":"string","minLength":1},"typing":{"type":"boolean"},"thread_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]}},"required":["room_id","participant_id","typing"],"additionalProperties":false}|
        )
      )
end
