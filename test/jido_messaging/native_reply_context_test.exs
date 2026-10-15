defmodule Jido.Messaging.NativeReplyContextTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.Factories, Delivery}
  alias Jido.Messaging.{RoomServer, Runtime}

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :reply_context_fixture
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  setup do
    start_supervised!(Instance)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "reply-context")
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    %{binding: binding}
  end

  test "native replies retain one-level context and same-room canonical parent", %{binding: binding} do
    parents =
      for room <- ["first-room", "second-room"] do
        assert {:ok, _} = accept(binding, fact(binding, room, "parent", %{"text" => room}))
        {:ok, canonical_room} = Instance.get_room_by_external_binding(:reply_context_fixture, binding.id, room)

        {:ok, message} =
          Instance.get_message_by_external_id(
            :reply_context_fixture,
            binding.id,
            "parent",
            canonical_room.id
          )

        message
      end

    for {room, parent} <- Enum.zip(["first-room", "second-room"], parents) do
      reply_context = %{
        "id" => "parent",
        "text" => "complete quoted context",
        "sender" => %{"id" => "quoted-user", "display_name" => "Quoted"}
      }

      reply =
        fact(binding, room, "reply", %{
          "reply_to_id" => "parent",
          "reply_context" => reply_context,
          "timestamp" => "2026-10-13T05:00:00Z",
          "thread_id" => "provider-thread",
          "text" => "complete reply"
        })

      before = Jido.Signal.to_map(reply)
      assert {:ok, _} = accept(binding, reply)
      {:ok, message} = Instance.get_message_by_external_id(:reply_context_fixture, binding.id, "reply", parent.room_id)
      assert message.reply_to_id == parent.id
      assert message.external_reply_to_id == "parent"
      assert message.metadata.reply_context == reply_context
      assert message.external_thread_id == "provider-thread"
      assert message.thread_id != nil
      assert {:ok, thread} = Instance.get_thread(message.thread_id)
      assert thread.room_id == parent.room_id
      server = RoomServer.whereis(Instance, parent.room_id)
      context = RoomServer.message_context(server, message.id)
      assert context.parent_signal == reply
      assert context.msg_context.timestamp == DateTime.to_unix(~U[2026-10-13 05:00:00Z], :millisecond)
      assert context.thread_id == thread.id
      assert context.msg_context.reply_to_id == parent.id
      assert Jido.Signal.to_map(reply) == before
      assert {:ok, []} = accept(binding, reply)
    end
  end

  defp fact(binding, room, id, extra) do
    Factories.message_received(
      binding,
      Map.merge(
        %{
          "delivery_id" => room <> id,
          "item_id" => room <> id,
          "room_id" => room,
          "message_id" => id,
          "sender" => %{"id" => "peer"},
          "text" => id
        },
        extra
      )
    )
  end

  defp accept(binding, fact) do
    {:ok, delivery} = Delivery.new(binding, fact.data["delivery_id"], [fact])
    Instance.accept_delivery(delivery)
  end
end
