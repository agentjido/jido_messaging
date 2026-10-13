defmodule Jido.Messaging.MediaPolicyOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Content.{Audio, File, Image, Video}
  alias Jido.Messaging.MediaPolicy

  defmodule MediaAdapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :media_fixture
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    @impl true
    def capabilities, do: [:text, :image, :audio, :video, :file]

    def content_capabilities, do: [:text, :image, :audio, :video, :file]
    @impl true
    def send_file(_room, _file, _opts), do: {:ok, %{id: "file"}}
    @impl true
    def delete_message(_room, _message, _opts), do: :ok
  end

  test "complete media unit retains order, bytes and type metadata" do
    raw = [
      %{
        "kind" => "image",
        "data" => "image-data",
        "media_type" => "image/png",
        "alt_text" => "full caption",
        "width" => 40,
        "height" => 30
      },
      %{kind: :audio, data: "audio-data", media_type: "audio/ogg", duration: 12, transcript: "complete transcript"},
      %{
        kind: :video,
        url: "https://fixture.invalid/video",
        media_type: "video/mp4",
        width: 80,
        height: 60,
        duration: 21,
        thumbnail_url: "https://fixture.invalid/thumb"
      },
      %{kind: :file, data: "file-data", filename: "owned.bin", media_type: "application/octet-stream"}
    ]

    assert {:ok, [image, audio, video, file], metadata} = MediaPolicy.normalize_inbound(raw)
    assert %Image{data: "image-data", media_type: "image/png", alt_text: "full caption", width: 40, height: 30} = image
    assert %Audio{data: "audio-data", duration: 12, transcript: "complete transcript"} = audio
    assert %Video{url: "https://fixture.invalid/video", width: 80, height: 60, duration: 21} = video
    assert %File{data: "file-data", filename: "owned.bin", size: 9} = file
    assert metadata.count == 4
    assert metadata.total_bytes == 29
    assert metadata.rejected == []
    assert Enum.map(metadata.accepted, & &1.kind) == [:image, :audio, :video, :file]
  end

  test "malformed middle media rejects the whole unit instead of returning a truncated list" do
    raw = [
      %{kind: :image, data: "kept", media_type: "image/png"},
      %{kind: :audio, data: "bad", media_type: "image/png"},
      %{kind: :file, data: "last", filename: "last.bin"}
    ]

    assert {:error, {:media_policy_denied, :invalid_media_type}, metadata} = MediaPolicy.normalize_inbound(raw)
    assert metadata.count == 2
    assert Enum.map(metadata.accepted, & &1.kind) == [:image, :file]
    assert [%{index: 1, reason: :invalid_media_type}] = metadata.rejected
  end

  test "explicit total size and count limits keep complete accepted bytes" do
    payload = [%{kind: :image, data: "abc"}, %{kind: :audio, data: "def"}]
    assert {:ok, [_, _], %{total_bytes: 6}} = MediaPolicy.normalize_inbound(payload, max_total_bytes: 6)

    assert {:error, {:media_policy_denied, :max_total_bytes_exceeded}, %{count: 1}} =
             MediaPolicy.normalize_inbound(payload, max_total_bytes: 5)

    assert {:error, {:media_policy_denied, :max_items_exceeded}, %{count: 1}} =
             MediaPolicy.normalize_inbound(payload, max_items: 1)

    assert {:error, {:media_policy_denied, :max_item_bytes_exceeded}, %{count: 0}} =
             MediaPolicy.normalize_inbound(%{kind: :file, data: "abc", size_bytes: 12}, max_item_bytes: 11)
  end

  test "outbound normalization retains all selected file fields without a provider call" do
    payload = %{
      "kind" => "video",
      "data" => "full-data",
      "media_type" => "video/mp4",
      "duration" => 7,
      "width" => 40,
      "height" => 30,
      "thumbnail_url" => "https://fixture.invalid/thumb"
    }

    assert {:ok, prepared, metadata} = MediaPolicy.prepare_outbound(payload, MediaAdapter, :send_media)
    assert prepared.data == "full-data"
    assert prepared.thumbnail_url == "https://fixture.invalid/thumb"
    assert prepared.duration == 7
    assert metadata.count == 1
    assert metadata.total_bytes == 9
  end
end
