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
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"name":{"type":"string"},"kind":{"enum":["direct","group","channel","thread","unknown"]}},"required":["request_id","name","kind"],"additionalProperties":false}|
        )
      )
end
