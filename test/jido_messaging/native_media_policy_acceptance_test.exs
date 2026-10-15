defmodule Jido.Messaging.NativeMediaPolicyAcceptanceTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.{AdapterTestKit.Factories, AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, Delivery}
  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.{Deduper, RoomServer, Runtime}

  defmodule Instance do
    use Jido.Messaging, runtime_profile: :core
  end

  setup do
    previous = Application.fetch_env(:jido_messaging, :media_policy)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_messaging, :media_policy, value)
        :error -> Application.delete_env(:jido_messaging, :media_policy)
      end
    end)

    start_supervised!(Instance)
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "media-policy", transport: transport)
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    {:ok, _} = Instance.subscribe_signals("jido.chat.message.received")
    {:ok, _} = Instance.subscribe_signals("jido.messaging.message.received")
    %{binding: binding, transport: transport}
  end

  for {name, policy} <- [
        {:item_bytes, [max_item_bytes: 2]},
        {:total_bytes, [max_total_bytes: 5]},
        {:item_count, [max_items: 1]},
        {:allowed_kinds, [allow: [:file]]}
      ] do
    test "#{name} denial writes no message and an exact-limit retry retains the whole media", context do
      binding = context.binding
      Application.put_env(:jido_messaging, :media_policy, unquote(policy))
      {:ok, first_ref} = Jido.Chat.put_resource(binding, "media", %{data: "abc", media_type: "image/png"})
      {:ok, second_ref} = Jido.Chat.put_resource(binding, "media", %{data: "def", media_type: "audio/ogg"})

      parent =
        Factories.message_received(binding, %{
          "delivery_id" => "unit",
          "item_id" => "media",
          "message_id" => "media",
          "text" => "complete text",
          "media" => [
            %{"kind" => "image", "resource_ref" => first_ref, "caption" => "complete caption"},
            %{"kind" => "audio", "resource_ref" => second_ref, "caption" => "complete transcript"}
          ]
        })

      original = Jido.Signal.to_map(parent)
      {:ok, delivery} = Delivery.new(binding, "unit", [parent])
      assert {:error, %Contract{}} = Instance.accept_delivery(delivery)
      assert {:ok, [room]} = Instance.list_rooms()
      assert {:ok, []} = Instance.list_messages(room.id)
      assert {:error, :not_found} = Instance.get_message_by_external_id(:test, binding.id, "media")
      assert Deduper.count(Instance) == 0
      assert_no_authority(room.id)
      refute_received {:signal, _}

      Application.put_env(:jido_messaging, :media_policy,
        max_items: 2,
        max_item_bytes: 3,
        max_total_bytes: 6,
        allow: [:image, :audio]
      )

      assert {:ok, [child]} = Instance.accept_delivery(delivery)
      assert_receive {:signal, ^parent}
      assert_receive {:signal, ^child}
      assert {:ok, message} = Instance.get_message(child.data["message_id"])

      assert [
               %Jido.Chat.Content.Text{text: "complete text"},
               %Jido.Chat.Content.Image{data: "abc", alt_text: "complete caption"},
               %Jido.Chat.Content.Audio{data: "def", transcript: "complete transcript"}
             ] = message.content

      assert message.metadata.media.count == 2
      assert message.metadata.media.total_bytes == 6
      assert message.metadata.media.rejected == []
      assert child.data["text"] == "complete text"
      assert Jido.Signal.Context.get(child, "causationid") == parent.id
      assert Jido.Signal.Trace.get(child).trace_id == Jido.Signal.Trace.get(parent).trace_id
      assert Jido.Signal.to_map(parent) == original
      assert_no_authority(room.id)
      assert {:ok, []} = Instance.accept_delivery(delivery)
      assert {:ok, [^message]} = Instance.list_messages(room.id)
      assert MockTransport.calls(context.transport) == []
      refute_receive {:signal, _}
    end
  end

  defp assert_no_authority(room_id) do
    {_adapter, state} = Runtime.get_persistence(Instance.__jido_messaging__(:runtime))
    assert :ets.info(state.room_memberships, :size) == 0
    assert :ets.info(state.memberships, :size) == 0
    assert :ets.info(state.principal_grants, :size) == 0
    room_state = RoomServer.get_state(RoomServer.via_tuple(Instance, room_id))
    assert room_state.registered_agents == %{}
    assert room_state.thread_assignments == %{}
    assert room_state.typing == %{}
  end
end
