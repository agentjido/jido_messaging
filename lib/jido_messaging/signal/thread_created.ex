defmodule Jido.Messaging.Signal.ThreadCreated do
  @moduledoc """
  Typed fact definition for `jido.messaging.thread.created`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.thread.created",
    dataschema: "urn:jido:messaging:schema:thread_created:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "thread_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "participant_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional()
        },
        strict: true
      )
end
