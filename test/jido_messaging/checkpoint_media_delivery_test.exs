defmodule Jido.Messaging.CheckpointMediaDeliveryTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Content.{Audio, File, Video}
  alias Jido.Messaging.{Deliver, MediaPolicy, OutboundGateway, Runtime}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Adapter do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :checkpoint_media
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(binding, _input), do: Jido.Chat.Delivery.new(binding, "empty", [])
    def content_capabilities, do: Agent.get(__MODULE__.Control, & &1.capabilities)
    @impl true
    def capabilities do
      file = if :image in content_capabilities(), do: :native, else: :unsupported
      %{send_message: :native, edit_message: :native, send_file: file, delete_message: :native}
    end

    @impl true
    def send_message(room, text, _opts), do: invoke(:send, {room, text}, "fallback-message")
    @impl true
    def edit_message(room, id, text, _opts), do: invoke(:edit, {room, id, text}, id)
    @impl true
    def send_file(room, upload, _opts), do: invoke(:upload, {room, upload}, "replacement")
    @impl true
    def delete_message(room, id, _opts) do
      case invoke(:delete, {room, id}, id) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    defp invoke(operation, payload, id) do
      Agent.get_and_update(__MODULE__.Control, fn state ->
        result = if state.fail == operation, do: {:error, :timeout}, else: {:ok, %{id: id}}
        {result, %{state | calls: state.calls ++ [{operation, payload}]}}
      end)
    end
  end

  setup do
    start_supervised!(%{
      id: Adapter.Control,
      start:
        {Agent, :start_link,
         [
           fn -> %{capabilities: [:text, :image, :audio, :video, :file], fail: nil, calls: []} end,
           [name: Adapter.Control]
         ]}
    })

    start_supervised!(Instance)
    {:ok, room} = Instance.create_room(%{type: :group})

    {:ok, message} =
      Instance.save_message(%{
        room_id: room.id,
        sender_id: "person",
        role: :user,
        content: [%{type: :text, text: "original complete content"}],
        external_id: "original"
      })

    context = %{
      channel: Adapter,
      bridge_id: "bridge",
      external_room_id: "provider-room",
      room: room,
      instance_module: Instance
    }

    {:ok, room: room, message: message, context: context}
  end

  defp calls, do: Agent.get(Adapter.Control, & &1.calls)
  defp policy_mode(fail), do: Agent.update(Adapter.Control, &%{&1 | fail: fail})
  defp media, do: %{kind: :image, data: "complete image bytes", media_type: "image/png"}

  test "media input conversion retains data, integer fields, and each declared kind" do
    raw = [
      %{"kind" => "AUDIO", "data" => "audio", "duration" => "12"},
      %{"kind" => "VIDEO", "data" => "video", "width" => "40", "height" => "bad"},
      %{"kind" => "FILE", "data" => "file", "size" => "4"}
    ]

    assert {:ok, [%Audio{duration: 12}, %Video{width: 40, height: nil}, %File{size: 4}], %{count: 3, total_bytes: 14}} =
             MediaPolicy.normalize_inbound(raw)

    assert {:error, {:media_policy_denied, :invalid_media_payload}, _} = MediaPolicy.normalize_inbound([:invalid])

    assert {:error, {:media_policy_denied, :unsupported_kind}, _} =
             MediaPolicy.normalize_inbound(%{kind: "unknown", data: "bytes"})

    assert {:ok, [], %{count: 0}} = MediaPolicy.normalize_inbound(nil)

    assert {:ok, [image], %{count: 1, rejected: [%{index: 1}]}} =
             MediaPolicy.normalize_inbound([media(), :invalid], on_policy_violation: :drop)

    assert image.data == media().data
    assert {:error, :invalid_media_payload, %{count: 0}} = MediaPolicy.prepare_outbound(:invalid, Adapter, :send_media)
    assert {:error, :unsupported_operation, %{count: 0}} = MediaPolicy.prepare_outbound(media(), Adapter, :unknown)
    assert {:ok, _, %{count: 1}} = MediaPolicy.prepare_outbound(media(), Adapter, :send_media)
  end

  test "invalid policy input uses bounded defaults and empty fallback text cannot dispatch" do
    config =
      MediaPolicy.config(
        max_items: 0,
        max_item_bytes: -1,
        max_total_bytes: nil,
        allow: ["UNKNOWN"],
        unsupported_policy: :invalid,
        on_policy_violation: :invalid,
        fallback_text: nil
      )

    assert config[:max_items] == 4
    assert config[:max_item_bytes] == 10_000_000
    assert config[:max_total_bytes] == 20_000_000
    assert config[:allow] == [:image, :audio, :video, :file]
    assert config[:unsupported_policy] == :reject
    assert config[:on_policy_violation] == :reject
    Agent.update(Adapter.Control, &%{&1 | capabilities: [:text]})

    assert {:error, {:unsupported_media, :image, causes}, _} =
             MediaPolicy.prepare_outbound(Map.put(media(), :fallback_text, " "), Adapter, :send_media,
               unsupported_policy: :fallback_text
             )

    assert :missing_fallback_text in causes
    assert calls() == []
  end

  test "media edits preserve complete canonical content and do not repeat gateway callbacks", context do
    assert {:ok, edited} = Deliver.edit_outgoing_media(Instance, context.message, media(), context.context)
    assert [%Jido.Chat.Content.Image{data: "complete image bytes"}] = edited.content
    assert edited.id == context.message.id
    assert edited.metadata.outbound_gateway.operation == :edit_media
    assert {:ok, ^edited} = Instance.get_message(edited.id)
    assert {:ok, _} = Deliver.edit_outgoing_media(Instance, context.message, media(), context.context)
    assert Enum.map(calls(), &elem(&1, 0)) == [:upload, :delete]

    assert {:error, :missing_external_message_id} =
             Deliver.edit_outgoing_media(Instance, %{context.message | external_id: nil}, media(), context.context)
  end

  test "a failed media edit retains its canonical record and stops at the selected attempt limit", context do
    policy_mode(:upload)

    assert {:error, _} =
             Deliver.edit_outgoing_media(Instance, context.message, media(), context.context, max_attempts: 1)

    assert Enum.map(calls(), &elem(&1, 0)) == [:upload]
    assert {:ok, original} = Instance.get_message(context.message.id)
    assert original == context.message
  end

  test "media edit fallback sends complete text through the edit path once", context do
    Agent.update(Adapter.Control, &%{&1 | capabilities: [:text]})
    payload = Map.put(media(), :fallback_text, "complete fallback")
    opts = [idempotency_key: "fallback-edit", media_policy: %{unsupported_policy: :fallback_text}]
    assert {:ok, result} = OutboundGateway.edit_media(Instance, context.context, "original", payload, opts)
    assert result.operation == :edit_media
    assert result.media.fallback
    assert {:ok, cached} = OutboundGateway.edit_media(Instance, context.context, "original", payload, opts)
    assert cached == %{result | idempotent: true}
    assert calls() == [{:edit, {"provider-room", "original", "complete fallback"}}]
    assert {:ok, original} = Instance.get_message(context.message.id)
    assert original == context.message
  end

  test "failed media delivery records a complete failed reply while retaining its parent", context do
    policy_mode(:upload)

    assert {:error, _} =
             Deliver.deliver_media_outgoing(Instance, context.message, media(), context.context, max_attempts: 1)

    assert {:ok, messages} = Instance.list_messages(context.room.id)
    assert length(messages) == 2
    failed = Enum.find(messages, &(&1.id != context.message.id))
    assert failed.status == :failed
    assert failed.reply_to_id == context.message.id
    assert [%Jido.Chat.Content.Image{data: "complete image bytes"}] = failed.content
    assert {:ok, original} = Instance.get_message(context.message.id)
    assert original == context.message
    assert Enum.map(calls(), &elem(&1, 0)) == [:upload]
    assert :ets.info(Runtime.request_table(Instance.__jido_messaging__(:runtime)), :size) == 0
  end
end
