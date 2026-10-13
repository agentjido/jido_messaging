defmodule Jido.Messaging.AdapterBridgeOptionScopeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport}
  alias Jido.Messaging.AdapterBridge

  test "fixed option keys work without relying on another module's atom loading" do
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "fixed-options", transport: transport)

    assert {:ok, result} =
             AdapterBridge.send_message(MockAdapter, "room", "complete text",
               binding: binding,
               request_id: "fixed-options",
               external_thread_id: "external-thread",
               thread_id: "canonical-thread",
               reply_to_id: "parent",
               format: :markdown,
               cursor: "must-not-reach-send",
               limit: 8,
               direction: :backward,
               topic_name: "must-not-reach-send"
             )

    assert result.message_id == "mock-message-1"
    assert [call] = MockTransport.calls(transport)
    assert call.payload.opts[:thread_id] == "external-thread"
    assert call.payload.opts[:reply_to_id] == "parent"
    assert call.payload.opts[:format] == "markdown"
    for key <- [:cursor, :limit, :direction, :topic_name], do: refute(Keyword.has_key?(call.payload.opts, key))
  end
end
