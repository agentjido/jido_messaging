defmodule JidoMessaging.Signal.Ext.CorrelationId do
  @moduledoc """
  Signal extension for message correlation tracking in JidoMessaging.

  This extension provides a simple `correlation_id` field for tracing related
  messages through the messaging pipeline. It's used to link:

  - Inbound messages to their processing events
  - Agent triggers to their responses
  - Delivery attempts to their outcomes

  ## Usage

  The correlation ID is automatically populated by `JidoMessaging.Signal` functions:

      # Automatically added when emitting signals
      JidoMessaging.Signal.emit_received(message, context)

      # The signal will have:
      # signal.extensions["correlationid"] == %{"id" => "msg_abc123"}

  ## Relationship to Jido.Signal.Ext.Trace

  This extension is complementary to the trace extension (`correlation` namespace):

  - **Trace extension**: Full distributed tracing with `trace_id`, `span_id`, `parent_span_id`
  - **CorrelationId extension**: Simple message-level correlation for messaging workflows

  Use trace extension for cross-service distributed tracing.
  Use this extension for message-level correlation within the messaging domain.

  ## Registration

  Call `ensure_registered/0` at application startup to register this extension:

      JidoMessaging.Signal.Ext.CorrelationId.ensure_registered()
  """

  use Jido.Signal.Ext,
    namespace: "correlationid",
    schema: [
      id: [type: :string, required: true, doc: "Correlation identifier for message tracing"]
    ]

  @doc """
  Ensures the extension is registered with the signal registry.

  This should be called at application startup or before using signals
  with correlation IDs. Safe to call multiple times.
  """
  @spec ensure_registered() :: :ok
  def ensure_registered do
    Jido.Signal.Ext.Registry.register(__MODULE__)
  end

  @impl true
  def to_attrs(%{id: id}) do
    %{"correlationid" => %{"id" => id}}
  end

  def to_attrs(id) when is_binary(id) do
    %{"correlationid" => %{"id" => id}}
  end

  @impl true
  def from_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, "correlationid") || Map.get(attrs, :correlationid) do
      %{"id" => id} -> %{id: id}
      %{id: id} -> %{id: id}
      _ -> nil
    end
  end
end
