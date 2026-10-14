defmodule Jido.Messaging.Signal.OperationCompleted do
  @moduledoc """
  Typed result definition for `jido.messaging.operation.completed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room operations; absence is permitted for non-room operations.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :result,
    type: "jido.messaging.operation.completed",
    dataschema: "urn:jido:messaging:schema:operation_completed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema: Jido.Messaging.Operations.Definitions.completed_schema()
end
