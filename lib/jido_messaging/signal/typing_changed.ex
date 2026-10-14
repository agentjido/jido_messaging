defmodule Jido.Messaging.Signal.TypingChanged do
  @moduledoc """
  Typed fact definition for `jido.messaging.participant.typing`.

  Data uses the protocol version 1 string-key schema. Canonical room subject.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.participant.typing",
    dataschema: "urn:jido:messaging:schema:participant_typing:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "room_id" => Zoi.string() |> Zoi.min(1),
          "participant_id" => Zoi.string() |> Zoi.min(1),
          "typing" => Zoi.boolean(),
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
