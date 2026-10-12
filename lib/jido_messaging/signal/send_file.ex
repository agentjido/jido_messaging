defmodule Jido.Messaging.Signal.SendFile do
  @moduledoc """
  Typed command definition for `jido.messaging.command.send_file`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.send_file",
    dataschema: "urn:jido:messaging:schema:command_send_file:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"resource_ref":{"type":"object","properties":{"id":{"type":"string","minLength":1},"scope":{"enum":["call"]},"binding_id":{"type":"string","minLength":1},"kind":{"enum":["file","media","stream","card","modal","result"]}},"required":["id","scope","binding_id","kind"],"additionalProperties":false},"thread_id":{"type":"string","minLength":1},"reply_to_id":{"type":"string","minLength":1},"format":{"enum":["plain","markdown","html"]},"bridge_id":{"type":"string","minLength":1}},"required":["request_id","room_id","resource_ref","bridge_id"],"additionalProperties":false}|
        )
      )
end
