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
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "name" => Zoi.string() |> Zoi.optional(),
          "kind" => Zoi.enum(["direct", "group", "channel", "thread", "unknown"]) |> Zoi.optional()
        },
        strict: true
      )
end
