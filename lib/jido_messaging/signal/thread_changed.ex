defmodule Jido.Messaging.Signal.ThreadChanged do
  @moduledoc """
  Typed fact definition for `jido.messaging.thread.changed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.thread.changed",
    dataschema: "urn:jido:messaging:schema:thread_changed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"thread_id":{"type":"string","minLength":1},"message_id":{"type":"string","minLength":1},"participant_id":{"type":"string","minLength":1},"change":{"enum":["updated","reopened","closed"]}},"required":["room_id","thread_id","change"],"additionalProperties":false}|
        )
      )
end
