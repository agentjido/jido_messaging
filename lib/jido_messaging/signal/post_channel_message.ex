defmodule Jido.Messaging.Signal.PostChannelMessage do
  @moduledoc """
  Typed command definition for `jido.messaging.command.post_channel_message`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.post_channel_message",
    dataschema: "urn:jido:messaging:schema:command_post_channel_message:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"text":{"type":"string"},"thread_id":{"type":"string","minLength":1},"reply_to_id":{"type":"string","minLength":1},"format":{"enum":["plain","markdown","html"]},"bridge_id":{"type":"string","minLength":1}},"required":["request_id","room_id","text","bridge_id"],"additionalProperties":false}|
        )
      )
end
