defmodule Jido.Messaging.Signal.MessageFailed do
  @moduledoc """
  Typed fact definition for `jido.messaging.message.failed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.message.failed",
    dataschema: "urn:jido:messaging:schema:message_failed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"message_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]},"bridge_id":{"type":"string","minLength":1},"code":{"enum":["provider_failure","persistence_failed","authorization_denied","delivery_failed","observation_failed"]}},"required":["room_id","code"],"additionalProperties":false}|
        )
      )
end
