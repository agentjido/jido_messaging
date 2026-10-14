defmodule Jido.Messaging.Signal.CreateRoom do
  @moduledoc """
  Typed command definition for `jido.messaging.command.create_room`.

  Data uses the protocol version 1 string-key schema. Canonical room subject if room_id is present; absent before creation.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.create_room",
    dataschema: "urn:jido:messaging:schema:command_create_room:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "name" => Zoi.string(),
          "kind" => Zoi.enum(["direct", "group", "channel", "thread"])
        },
        strict: true
      )
end
