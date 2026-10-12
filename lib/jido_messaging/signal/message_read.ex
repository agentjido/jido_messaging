defmodule Jido.Messaging.Signal.MessageRead do
  @moduledoc """
  Typed fact definition for `jido.messaging.message.read`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.message.read",
    dataschema: "urn:jido:messaging:schema:message_read:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"message_id":{"type":"string","minLength":1},"participant_id":{"type":"string","minLength":1},"timestamp":{"type":"string"}},"required":["room_id","message_id","participant_id"],"additionalProperties":false}|
        )
      )
end
