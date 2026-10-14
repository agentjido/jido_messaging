defmodule Jido.Messaging.Signal.LoadOptions do
  @moduledoc """
  Typed query definition for `jido.messaging.query.load_options`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :query,
    type: "jido.messaging.query.load_options",
    dataschema: "urn:jido:messaging:schema:query_load_options:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "interaction_id" => Zoi.string() |> Zoi.min(1),
          "query" => Zoi.string(),
          "thread_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "reply_to_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "format" => Zoi.enum(["plain", "markdown", "html"]) |> Zoi.optional(),
          "action_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "room_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "view_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "user_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "limit" => Zoi.integer() |> Zoi.gte(1) |> Zoi.optional(),
          "bridge_id" => Zoi.string() |> Zoi.min(1)
        },
        strict: true
      )
end
