defmodule Jido.Messaging.Signal.GetThreadParticipants do
  @moduledoc """
  Typed query definition for `jido.messaging.query.get_thread_participants`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :query,
    type: "jido.messaging.query.get_thread_participants",
    dataschema: "urn:jido:messaging:schema:query_get_thread_participants:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1),
          "thread_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "reply_to_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "format" => Zoi.enum(["plain", "markdown", "html"]) |> Zoi.optional(),
          "bridge_id" => Zoi.string() |> Zoi.min(1)
        },
        strict: true
      )
end
