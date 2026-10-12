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
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"sender_id":{"type":"string","minLength":1},"text":{"type":"string"},"role":{"enum":["user","assistant","system","tool"]},"thread_id":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]}},"required":["request_id","room_id","sender_id","text"],"additionalProperties":false}|
        )
      )
end
