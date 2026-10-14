defmodule Jido.Messaging.Signal.PostMessage do
  @moduledoc """
  Typed command definition for `jido.messaging.command.post_message`.

  Data uses the protocol version 1 string-key schema. Canonical room subject if room_id is present; absent before creation.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.post_message",
    dataschema: "urn:jido:messaging:schema:command_post_message:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1),
          "sender_id" => Zoi.string() |> Zoi.min(1),
          "text" => Zoi.string(),
          "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional(),
          "thread_id" =>
            Zoi.union([
              Zoi.string() |> Zoi.min(1),
              Zoi.null()
            ])
            |> Zoi.optional()
        },
        strict: true
      )
end
