defmodule Jido.Messaging.Signal.AgentCompleted do
  @moduledoc """
  Typed fact definition for `jido.messaging.agent.completed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.agent.completed",
    dataschema: "urn:jido:messaging:schema:agent_completed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "agent_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "thread_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "code" => Zoi.string() |> Zoi.optional()
        },
        strict: true
      )
end
