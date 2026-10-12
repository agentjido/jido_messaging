defmodule Jido.Messaging.Signal.AgentStarted do
  @moduledoc """
  Typed fact definition for `jido.messaging.agent.started`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.agent.started",
    dataschema: "urn:jido:messaging:schema:agent_started:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"room_id":{"type":"string","minLength":1},"agent_id":{"type":"string","minLength":1},"message_id":{"type":"string","minLength":1},"thread_id":{"type":"string","minLength":1},"code":{"type":"string"}},"required":["room_id","agent_id"],"additionalProperties":false}|
        )
      )
end
