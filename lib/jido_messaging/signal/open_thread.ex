defmodule Jido.Messaging.Signal.OpenThread do
  @moduledoc """
  Typed command definition for `jido.messaging.command.open_thread`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.open_thread",
    dataschema: "urn:jido:messaging:schema:command_open_thread:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1),
          "thread_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "reply_to_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "format" => Zoi.enum(["plain", "markdown", "html"]) |> Zoi.optional(),
          "bridge_id" => Zoi.string() |> Zoi.min(1),
          "topic_name" => Zoi.string() |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
end
