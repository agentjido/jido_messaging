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
      Zoi.map(
        %{
          "instance_id" => Zoi.string() |> Zoi.min(1),
          "bridge_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "code" => Zoi.string() |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
end
