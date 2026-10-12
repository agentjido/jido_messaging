defmodule Jido.Messaging.Signal.OpenDm do
  @moduledoc """
  Typed command definition for `jido.messaging.command.open_dm`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.open_dm",
    dataschema: "urn:jido:messaging:schema:command_open_dm:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"user_id":{"type":"string","minLength":1},"thread_id":{"type":"string","minLength":1},"reply_to_id":{"type":"string","minLength":1},"format":{"enum":["plain","markdown","html"]},"bridge_id":{"type":"string","minLength":1}},"required":["request_id","user_id","bridge_id"],"additionalProperties":false}|
        )
      )
end
