defmodule Jido.Messaging.Signal.InstanceConnecting do
  @moduledoc """
  Typed fact definition for `jido.messaging.instance.connecting`.

  Data uses the protocol version 1 string-key schema. Absent; this is an instance lifecycle fact.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.instance.connecting",
    dataschema: "urn:jido:messaging:schema:instance_connecting:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"instance_id":{"type":"string","minLength":1},"bridge_id":{"type":"string","minLength":1},"code":{"type":"string"}},"required":["instance_id"],"additionalProperties":false}|
        )
      )
end
