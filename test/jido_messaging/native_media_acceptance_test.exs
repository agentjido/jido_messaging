defmodule Jido.Messaging.NativeMediaAcceptanceTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.Factories, Delivery}
  alias Jido.Messaging.Runtime

  defmodule Instance do
    use Jido.Messaging
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :native_media_fixture
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  setup do
    start_supervised!(Instance)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "owned-media")
    :ok = Runtime.register_binding(Instance.__jido_messaging__(:runtime), binding)
    %{binding: binding}
  end

  test "native media reference retains complete private bytes in the accepted record", %{binding: binding} do
    private = %{
      kind: :image,
      data: "full private image bytes",
      media_type: "image/png",
      alt_text: "full caption",
      width: 40,
      height: 30
    }

    {:ok, ref} = Jido.Chat.put_resource(binding, "media", private)

    fact =
      Factories.message_received(binding, %{
        "delivery_id" => "owned",
        "item_id" => "owned",
        "room_id" => "provider-room",
        "message_id" => "provider-message",
        "sender" => %{"id" => "provider-user"},
        "text" => "message text",
        "media" => [
          %{"kind" => "image", "resource_ref" => ref, "media_type" => "image/png", "caption" => "full caption"}
        ]
      })

    original = Jido.Signal.to_map(fact)
    {:ok, delivery} = Delivery.new(binding, "owned", [fact])
    assert {:ok, _} = Instance.accept_delivery(delivery)
    assert {:ok, message} = Instance.get_message_by_external_id(:native_media_fixture, binding.id, "provider-message")

    assert [
             %Jido.Chat.Content.Text{text: "message text"},
             %Jido.Chat.Content.Image{data: "full private image bytes", alt_text: "full caption", width: 40, height: 30}
           ] = message.content

    assert message.metadata.media.count == 1
    assert Jido.Signal.to_map(fact) == original
    refute Jason.encode!(original) =~ "full private image bytes"
    assert {:ok, []} = Instance.accept_delivery(delivery)
    assert {:ok, [^message]} = Instance.list_messages(message.room_id)
  end

  for state <- [:cancelled, :failed, :expired, :invalid_value, :wrong_kind] do
    test "#{state} second media rejects before canonical writes", %{binding: binding} do
      private = %{kind: :image, data: "complete data", media_type: "image/png"}
      {:ok, first} = Jido.Chat.put_resource(binding, "media", private)
      ref = unavailable_ref(binding, unquote(state), private)
      fact = media_fact(binding, [first, ref])
      {:ok, delivery} = Delivery.new(binding, "owned", [fact])
      assert {:error, _} = Instance.accept_delivery(delivery)
      assert {:ok, []} = Instance.list_rooms()

      assert {:error, :not_found} =
               Instance.get_message_by_external_id(:native_media_fixture, binding.id, "provider-message")

      {:ok, replacement} = Jido.Chat.put_resource(binding, "media", private)
      {:ok, valid} = Delivery.new(binding, "owned", [media_fact(binding, [first, replacement])])
      assert {:ok, _} = Instance.accept_delivery(valid)
      assert {:ok, message} = Instance.get_message_by_external_id(:native_media_fixture, binding.id, "provider-message")
      assert length(message.content) == 3
      assert {:ok, []} = Instance.accept_delivery(valid)
      assert {:ok, [^message]} = Instance.list_messages(message.room_id)
    end
  end

  test "another caller cannot resolve media or create records", %{binding: binding} do
    {:ok, ref} = Jido.Chat.put_resource(binding, "media", %{data: "owned", kind: :image})
    {:ok, delivery} = Delivery.new(binding, "owned", [media_fact(binding, [ref])])
    assert {:error, _} = Task.async(fn -> Instance.accept_delivery(delivery) end) |> Task.await()
    assert {:ok, []} = Instance.list_rooms()
    assert {:ok, _} = Instance.accept_delivery(delivery)
  end

  test "all native media kinds retain order and selected private fields", %{binding: binding} do
    kinds = ["image", "audio", "video", "file"]

    media =
      for kind <- kinds do
        {:ok, ref} =
          Jido.Chat.put_resource(binding, "media", %{
            "data" => kind <> "-bytes",
            "media_type" => kind <> "/fixture",
            "filename" => kind <> ".bin",
            "duration" => 7,
            "width" => 8,
            "height" => 9,
            "provider" => %{"token" => "private-only"}
          })

        %{"kind" => kind, "resource_ref" => ref, "caption" => "complete caption"}
      end

    fact =
      Factories.message_received(binding, %{
        "delivery_id" => "owned",
        "item_id" => "owned",
        "room_id" => "provider-room",
        "message_id" => "provider-message",
        "sender" => %{"id" => "provider-user"},
        "text" => "message text",
        "media" => media
      })

    {:ok, delivery} = Delivery.new(binding, "owned", [fact])
    assert {:ok, _} = Instance.accept_delivery(delivery)
    assert {:ok, message} = Instance.get_message_by_external_id(:native_media_fixture, binding.id, "provider-message")
    assert [_, image, audio, video, file] = message.content
    assert image.data == "image-bytes"
    assert image.alt_text == "complete caption"
    assert audio.data == "audio-bytes"
    assert audio.transcript == "complete caption"
    assert video.data == "video-bytes"
    assert video.duration == 7
    assert video.width == 8
    assert file.data == "file-bytes"
    assert file.filename == "file.bin"
    assert message.metadata.media.count == 4
    refute inspect(message) =~ "private-only"
  end

  defp media_fact(binding, refs) do
    Factories.message_received(binding, %{
      "delivery_id" => "owned",
      "item_id" => "owned",
      "room_id" => "provider-room",
      "message_id" => "provider-message",
      "sender" => %{"id" => "provider-user"},
      "text" => "message text",
      "media" => Enum.map(refs, &%{"kind" => "image", "resource_ref" => &1, "media_type" => "image/png"})
    })
  end

  defp unavailable_ref(binding, :invalid_value, _private) do
    {:ok, ref} = Jido.Chat.put_resource(binding, "media", :invalid)
    ref
  end

  defp unavailable_ref(binding, :wrong_kind, private) do
    {:ok, ref} = Jido.Chat.put_resource(binding, "result", private)
    ref
  end

  defp unavailable_ref(binding, :expired, private) do
    {:ok, ref} = Jido.Chat.Resources.put(binding, "media", private, ttl_ms: 0)
    ref
  end

  defp unavailable_ref(binding, state, private) do
    {:ok, ref} = Jido.Chat.put_resource(binding, "media", private)
    if state == :cancelled, do: Jido.Chat.cancel_resource(binding, ref), else: Jido.Chat.Resources.fail(binding, ref)
    ref
  end
end
