defmodule Jido.Messaging.Signal.InstanceStopped do
  @moduledoc """
  Typed fact definition for `jido.messaging.instance.stopped`.

  Data uses the protocol version 1 string-key schema. Absent; this is an instance lifecycle fact.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.instance.stopped",
    dataschema: "urn:jido:messaging:schema:instance_stopped:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "instance_id" => Zoi.string() |> Zoi.min(1),
          "bridge_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "code" => Zoi.string() |> Zoi.optional()
        },
        strict: true
      )
end
