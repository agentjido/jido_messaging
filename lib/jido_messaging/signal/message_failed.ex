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
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "message_id" =>
            Zoi.union([
              Zoi.string() |> Zoi.min(1),
              Zoi.null()
            ])
            |> Zoi.optional(),
          "bridge_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "code" =>
            Zoi.enum([
              "provider_failure",
              "persistence_failed",
              "authorization_denied",
              "delivery_failed",
              "observation_failed"
            ])
        },
        strict: true
      )
end
