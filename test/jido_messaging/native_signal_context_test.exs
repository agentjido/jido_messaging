defmodule Jido.Messaging.NativeSignalContextTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Events
  alias Jido.Signal.{Context, Serialization, Trace}

  test "runtime events use native W3C trace context" do
    assert {:ok, signal} = Events.new(:room_created, __MODULE__, "room", %{"room_id" => "room"})
    assert %Trace{} = Trace.get(signal)
    assert is_binary(Context.get(signal, "traceparent"))
    refute Map.has_key?(signal.extensions, "correlationid")
    assert {:ok, wire} = Serialization.serialize(signal)
    assert {:ok, decoded} = Serialization.deserialize(wire)
    assert decoded == signal
  end

  test "the child trace and causation identify the unchanged direct parent" do
    assert {:ok, parent} = Events.new(:room_created, __MODULE__, "room", %{"room_id" => "room"})
    original = Jido.Signal.to_map(parent)

    assert {:ok, child} =
             Events.new(
               :message_received,
               __MODULE__,
               "room",
               %{
                 "message_id" => "message",
                 "sender_id" => "sender",
                 "text" => "hello",
                 "role" => "user",
                 "status" => "received"
               },
               parent_signal: parent
             )

    assert Context.get(child, "causationid") == parent.id
    parent_trace = Trace.get(parent)
    child_trace = Trace.get(child)
    assert child_trace.trace_id == parent_trace.trace_id
    assert child_trace.span_id != parent_trace.span_id
    assert Jido.Signal.to_map(parent) == original
  end

  test "direct parent identity is a flat approved context value" do
    assert {:ok, signal} =
             Events.new(:room_created, __MODULE__, "room", %{}, causation_id: "parent-id")

    assert Context.get(signal, "causationid") == "parent-id"
    assert {:error, _} = Events.new(:room_created, __MODULE__, "room", %{}, causation_id: %{id: "bad"})
  end
end
