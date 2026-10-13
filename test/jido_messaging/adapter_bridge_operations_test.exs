defmodule Jido.Messaging.AdapterBridgeOperationsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{AdapterTestKit.MockAdapter, AdapterTestKit.MockTransport, FileUpload}
  alias Jido.Messaging.AdapterBridge

  setup do
    transport = start_supervised!(MockTransport)
    {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "bridge-operations", transport: transport)
    %{binding: binding, transport: transport}
  end

  test "media replacement uses two stable operation identities and complete private upload", context do
    payload = %{
      "kind" => "video",
      "data" => "complete-private-bytes",
      "media_type" => "video/mp4",
      "filename" => "complete.mp4",
      "size_bytes" => 22,
      "width" => 80,
      "height" => 60,
      "duration" => 12,
      "thumbnail_url" => "https://fixture.invalid/thumb",
      "alt_text" => "complete caption",
      "transcript" => "complete transcript",
      "metadata" => %{"private-context" => "retained"}
    }

    opts = [binding: context.binding, request_id: "replace-once"]
    assert {:ok, replacement} = AdapterBridge.edit_media(MockAdapter, "room", "old-message", payload, opts)
    assert replacement.status == :edited
    assert replacement.metadata.replacement == %{replaced_message_id: "old-message", delete_status: :deleted}

    assert [send_call, delete_call] = MockTransport.calls(context.transport)
    assert send_call.operation == :send_file
    assert delete_call.operation == :delete_message
    assert delete_call.payload.message_id == "old-message"
    assert %FileUpload{} = file = send_call.payload.file
    assert file.kind == :video
    assert file.data == "complete-private-bytes"
    assert file.filename == "complete.mp4"
    assert file.width == 80
    assert file.height == 60
    assert file.duration == 12

    assert file.metadata == %{
             "private-context" => "retained",
             thumbnail_url: "https://fixture.invalid/thumb",
             alt_text: "complete caption",
             transcript: "complete transcript"
           }

    assert {:ok, ^replacement} = AdapterBridge.edit_media(MockAdapter, "room", "old-message", payload, opts)
    assert MockTransport.calls(context.transport) == [send_call, delete_call]

    assert {:ok, changed_target} = AdapterBridge.edit_media(MockAdapter, "room", "changed-message", payload, opts)
    assert changed_target.metadata.replacement.delete_status == :delete_failed
    assert %Jido.Chat.Errors.Contract{code: :request_conflict} = changed_target.metadata.replacement.delete_reason
    assert MockTransport.calls(context.transport) == [send_call, delete_call]
  end

  test "failed upload never deletes the old message", context do
    :ok = MockTransport.stub(context.transport, :send_file, {:error, :timeout})
    opts = [binding: context.binding, request_id: "failed-replacement"]

    assert {:error, _} =
             AdapterBridge.edit_media(MockAdapter, "room", "old-message", %{kind: :image, data: "complete"}, opts)

    assert [%{operation: :send_file}] = MockTransport.calls(context.transport)
  end

  test "failed old-message delete keeps the successful replacement and exact failure", context do
    :ok = MockTransport.stub(context.transport, :delete_message, {:error, :timeout})

    assert {:ok, replacement} =
             AdapterBridge.edit_media(MockAdapter, "room", "old-message", %{kind: :image, data: "complete"},
               binding: context.binding,
               request_id: "delete-failed"
             )

    assert replacement.metadata.replacement.delete_status == :delete_failed

    assert replacement.metadata.replacement.delete_reason == %{
             class: :recoverable,
             reason: {:provider_operation_failed, "provider_failure"}
           }

    assert Enum.map(MockTransport.calls(context.transport), & &1.operation) == [:send_file, :delete_message]
  end

  test "repeated media request retains its resource identity and rejects changed bytes", context do
    opts = [binding: context.binding, request_id: "send-once"]
    payload = %{kind: :image, data: "complete"}
    assert {:ok, result} = AdapterBridge.send_media(MockAdapter, "room", payload, opts)
    assert {:ok, ^result} = AdapterBridge.send_media(MockAdapter, "room", payload, opts)
    assert [%{operation: :send_file}] = MockTransport.calls(context.transport)

    assert {:error, %Jido.Chat.Errors.Contract{code: :request_conflict}} =
             AdapterBridge.send_media(MockAdapter, "room", %{payload | data: "changed"}, opts)

    assert [%{operation: :send_file}] = MockTransport.calls(context.transport)
  end

  test "a prepared media resource cannot be used by a foreign caller before execution", context do
    file = FileUpload.new(%{kind: :image, data: "complete"})
    {:ok, ref} = Jido.Chat.put_resource(context.binding, "file", file)
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(file, [:deterministic]))
    :ets.insert(context.binding.resources, {{:messaging_media_resource, "prepared"}, digest, ref})

    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_owner_mismatch}} =
             Task.async(fn ->
               AdapterBridge.send_media(MockAdapter, "room", %{kind: :image, data: "complete"},
                 binding: context.binding,
                 request_id: "prepared"
               )
             end)
             |> Task.await()

    assert MockTransport.calls(context.transport) == []
  end

  test "wrong captured adapter binding rejects before a transport callback", context do
    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_binding}} =
             AdapterBridge.send_message(__MODULE__, "room", "text", binding: context.binding)

    assert MockTransport.calls(context.transport) == []
  end

  for state <- [:cancelled, :failed, :expired] do
    test "#{state} prepared media rejects without an upload or delete", context do
      file = FileUpload.new(%{kind: :image, data: "complete"})

      {:ok, ref} =
        Jido.Chat.put_resource(context.binding, "file", file,
          ttl_ms: if(unquote(state) == :expired, do: 0, else: 60_000)
        )

      case unquote(state) do
        :cancelled -> assert :ok = Jido.Chat.cancel_resource(context.binding, ref)
        :failed -> assert :ok = Jido.Chat.Resources.fail(context.binding, ref)
        :expired -> :ok
      end

      digest = :crypto.hash(:sha256, :erlang.term_to_binary(file, [:deterministic]))
      :ets.insert(context.binding.resources, {{:messaging_media_resource, "unavailable"}, digest, ref})

      assert {:error, %{class: :fatal, reason: {:provider_operation_failed, code}}} =
               AdapterBridge.send_media(MockAdapter, "room", %{kind: :image, data: "complete"},
                 binding: context.binding,
                 request_id: "unavailable"
               )

      assert code in ["resource_cancelled", "resource_failure", "resource_expired"]
      assert MockTransport.calls(context.transport) == []
    end
  end
end
