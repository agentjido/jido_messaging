defmodule Jido.Messaging.Signal.ReactionAdded do
  @moduledoc """
  Typed fact definition for `jido.messaging.message.reaction_added`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.message.reaction_added",
    dataschema: "urn:jido:messaging:schema:message_reaction_added:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "message_id" => Zoi.string() |> Zoi.min(1),
          "participant_id" => Zoi.string() |> Zoi.min(1),
          "reaction" => Zoi.string() |> Zoi.min(1)
        },
        strict: true
      )
end
