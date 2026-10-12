defmodule Jido.Messaging.Signal.FetchChannelMessages do
  @moduledoc """
  Typed query definition for `jido.messaging.query.fetch_channel_messages`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :query,
    type: "jido.messaging.query.fetch_channel_messages",
    dataschema: "urn:jido:messaging:schema:query_fetch_channel_messages:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"thread_id":{"type":"string","minLength":1},"reply_to_id":{"type":"string","minLength":1},"format":{"enum":["plain","markdown","html"]},"cursor":{"anyOf":[{"type":"string","minLength":1},{"type":"null"}]},"limit":{"type":"integer","minimum":1},"bridge_id":{"type":"string","minLength":1},"direction":{"enum":["forward","backward"]}},"required":["request_id","room_id","bridge_id"],"additionalProperties":false}|
        )
      )
end
