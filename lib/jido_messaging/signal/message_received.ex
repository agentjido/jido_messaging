defmodule Jido.Messaging.Signal.MessageReceived do
  @moduledoc """
  Typed fact definition for `jido.messaging.message.received`.

  Data uses the protocol version 1 string-key schema. Canonical room subject; thread identity is data.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.message.received",
    dataschema: "urn:jido:messaging:schema:message_received:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"message":{"type":"object","properties":{"id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"text":{"type":"string"},"sender":{"type":"object","properties":{"id":{"type":"string","minLength":1},"username":{"type":"string"},"display_name":{"type":"string"},"is_bot":{"type":"boolean"},"is_self":{"type":"boolean"}},"required":["id"],"additionalProperties":false},"thread_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]},"reply_to_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]},"media":{"type":"array","items":{"type":"object","properties":{"kind":{"enum":["image","audio","video","file"]},"resource_ref":{"type":"object","properties":{"id":{"type":"string","minLength":1},"scope":{"enum":["call"]},"binding_id":{"type":"string","minLength":1},"kind":{"enum":["file","media","stream","card","modal","result"]}},"required":["id","scope","binding_id","kind"],"additionalProperties":false},"name":{"type":"string"},"media_type":{"type":"string"},"caption":{"type":"string"}},"required":["kind","resource_ref"],"additionalProperties":false}},"timestamp":{"type":"string"},"status":{"enum":["sending","sent","delivered","read","failed","received","pending","updated","deleted"]},"role":{"enum":["user","assistant","system","tool"]}},"required":["id","room_id"],"additionalProperties":false},"message_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"thread_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]},"reply_to_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]},"sender_id":{"type":"string","minLength":1},"text":{"type":"string"},"role":{"enum":["user","assistant","system","tool"]},"status":{"enum":["sending","sent","delivered","read","failed","received","pending","updated","deleted"]},"external_room_id":{"type":"string","minLength":1},"external_message_id":{"type":"string","minLength":1},"bridge_id":{"type":"string","minLength":1}},"required":["message_id","room_id","sender_id"],"additionalProperties":false}|
        )
      )
end
