defmodule Jido.Messaging.Signal.PresenceChanged do
  @moduledoc """
  Typed fact definition for `jido.messaging.participant.presence_changed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.participant.presence_changed",
    dataschema: "urn:jido:messaging:schema:participant_presence_changed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "participant_id" => Zoi.string() |> Zoi.min(1),
          "presence" => Zoi.enum(["online", "away", "busy", "offline"])
        },
        unrecognized_keys: :error
      )
end
