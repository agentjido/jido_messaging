defmodule Jido.Messaging.Signal.InstanceDisconnected do
  @moduledoc """
  Typed fact definition for `jido.messaging.instance.disconnected`.

  Data uses the protocol version 1 string-key schema. Absent; this is an instance lifecycle fact.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.instance.disconnected",
    dataschema: "urn:jido:messaging:schema:instance_disconnected:1",
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
