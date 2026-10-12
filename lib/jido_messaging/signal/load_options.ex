defmodule Jido.Messaging.Signal.LoadOptions do
  @moduledoc """
  Typed query definition for `jido.messaging.query.load_options`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :query,
    type: "jido.messaging.query.load_options",
    dataschema: "urn:jido:messaging:schema:query_load_options:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.from_json_schema(
        Jason.decode!(
          ~S|{"type":"object","properties":{"request_id":{"type":"string","minLength":1},"interaction_id":{"type":"string","minLength":1},"query":{"type":"string"},"thread_id":{"type":"string","minLength":1},"reply_to_id":{"type":"string","minLength":1},"format":{"enum":["plain","markdown","html"]},"action_id":{"type":"string","minLength":1},"room_id":{"type":"string","minLength":1},"view_id":{"type":"string","minLength":1},"user_id":{"type":"string","minLength":1},"limit":{"type":"integer","minimum":1},"bridge_id":{"type":"string","minLength":1}},"required":["request_id","interaction_id","query","bridge_id"],"additionalProperties":false}|
        )
      )
end
