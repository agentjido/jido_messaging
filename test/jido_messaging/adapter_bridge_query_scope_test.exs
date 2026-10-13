defmodule Jido.Messaging.AdapterBridgeQueryScopeTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport}
  alias Jido.Messaging.AdapterBridge

  setup do
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "query-scope", transport: transport)
    %{binding: binding, transport: transport}
  end

  test "thread result keeps external thread and delivery room with ordered selected options", context do
    :ok =
      MockTransport.stub(
        context.transport,
        :open_thread,
        {:ok,
         %{
           external_thread_id: "provider-thread",
           external_room_id: "parent-room",
           delivery_external_room_id: "thread-room",
           name: "Complete thread name",
           raw: %{token: "private-provider-value"}
         }}
      )

    opts = [binding: context.binding, request_id: "thread-once", topic_name: "Complete thread name", cursor: "ignored"]

    assert {:ok, result} =
             AdapterBridge.operation(
               MockAdapter,
               :open_thread,
               %{"room_id" => "parent-room", "message_id" => "root"},
               opts
             )

    assert result.external_thread_id == "provider-thread"
    assert result.delivery_external_room_id == "thread-room"
    assert result["name"] == "Complete thread name"
    refute inspect(result) =~ "private-provider-value"
    assert [call] = MockTransport.calls(context.transport)
    assert call.operation == :open_thread
    assert call.payload.opts[:topic_name] == "Complete thread name"
    refute Keyword.has_key?(call.payload.opts, :cursor)

    assert {:ok, ^result} =
             AdapterBridge.operation(
               MockAdapter,
               :open_thread,
               %{"room_id" => "parent-room", "message_id" => "root"},
               opts
             )

    assert MockTransport.calls(context.transport) == [call]
  end

  test "paged query keeps every message, cursor and private provider option selection", context do
    :ok =
      MockTransport.stub(
        context.transport,
        :fetch_messages,
        {:ok,
         %{
           messages: [%{id: "one", text: "complete one"}, %{id: "two", text: "complete two"}],
           next_cursor: "next-page",
           complete: false
         }}
      )

    opts = [binding: context.binding, request_id: "page-once", cursor: "current-page", limit: 2, direction: :backward]
    assert {:ok, result} = AdapterBridge.operation(MockAdapter, :fetch_messages, %{"room_id" => "room"}, opts)
    assert Enum.map(result["messages"], & &1["id"]) == ["one", "two"]
    assert Enum.map(result["messages"], & &1["text"]) == ["complete one", "complete two"]
    assert result["next_cursor"] == "next-page"
    assert result["complete"] == false
    assert [call] = MockTransport.calls(context.transport)
    assert call.payload.opts[:cursor] == "current-page"
    assert call.payload.opts[:limit] == 2
    assert call.payload.opts[:direction] == :backward
    assert {:ok, ^result} = AdapterBridge.operation(MockAdapter, :fetch_messages, %{"room_id" => "room"}, opts)
    assert MockTransport.calls(context.transport) == [call]
  end

  test "unsupported read acknowledgement retains its safe error without a callback", context do
    assert {:error, :unsupported} =
             AdapterBridge.mark_as_read(MockAdapter, "room", "message", binding: context.binding, request_id: "read")

    assert MockTransport.calls(context.transport) == []
  end
end
