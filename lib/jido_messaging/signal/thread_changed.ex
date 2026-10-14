defmodule Jido.Messaging.Signal.ThreadChanged do
  @moduledoc """
  Typed fact definition for `jido.messaging.thread.changed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.thread.changed",
    dataschema: "urn:jido:messaging:schema:thread_changed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "thread_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "participant_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "change" => Zoi.enum(["updated", "reopened", "closed"])
        },
        unrecognized_keys: :error
      )
end
