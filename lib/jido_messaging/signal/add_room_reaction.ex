defmodule Jido.Messaging.Signal.AddRoomReaction do
  @moduledoc """
  Typed command definition for `jido.messaging.command.add_room_reaction`.

  Data uses the protocol version 1 string-key schema. Canonical room subject if room_id is present; absent before creation.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.add_room_reaction",
    dataschema: "urn:jido:messaging:schema:command_add_room_reaction:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1),
          "participant_id" => Zoi.string() |> Zoi.min(1),
          "reaction" => Zoi.string() |> Zoi.min(1)
        },
        unrecognized_keys: :error
      )
end
