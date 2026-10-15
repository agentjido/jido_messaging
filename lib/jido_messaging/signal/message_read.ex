defmodule Jido.Messaging.Signal.MessageRead do
  @moduledoc """
  Typed fact definition for `jido.messaging.message.read`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.message.read",
    dataschema: "urn:jido:messaging:schema:message_read:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1),
          "participant_id" => Zoi.string() |> Zoi.min(1),
          "timestamp" => Zoi.string() |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
end
