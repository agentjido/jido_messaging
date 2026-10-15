defmodule Jido.Messaging.Signal.OperationFailed do
  @moduledoc """
  Typed result definition for `jido.messaging.operation.failed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room operations; absence is permitted for non-room operations.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :result,
    type: "jido.messaging.operation.failed",
    dataschema: "urn:jido:messaging:schema:operation_failed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema: Jido.Messaging.Operations.Definitions.failed_schema()
end
