defmodule Jido.Messaging.Signal.RoomCreated do
  @moduledoc """
  Typed fact definition for `jido.messaging.room.created`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.room.created",
    dataschema: "urn:jido:messaging:schema:room_created:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"name":{"type":"string"},"kind":{"enum":["direct","group","channel","thread","unknown"]}},"required":["room_id"],"additionalProperties":false}|
        )
      )
end
