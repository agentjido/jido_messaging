defmodule Jido.Messaging.CheckpointBridgeContractTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.AdapterTestKit.{MockAdapter, MockTransport}
  alias Jido.Messaging.{AdapterBridge, BridgePlugin, BridgeRegistry}

  defmodule PreferredCapabilities do
    def content_capabilities, do: [:text, :image, :text, "invalid", nil]
    def capabilities, do: [:wrong]
    def verify_sender(_incoming, _raw), do: {:error, :unverified_sender}
    def sanitize_outbound(outbound, opts), do: {:ok, Map.put(outbound, :format, opts[:format])}
  end

  setup do
    BridgeRegistry.clear()
    dir = Path.join(System.tmp_dir!(), "checkpoint-manifests-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp manifest(overrides \\ %{}) do
    Map.merge(
      %{"manifest_version" => 1, "id" => "checkpoint_bridge", "adapter_module" => Atom.to_string(MockAdapter)},
      overrides
    )
  end

  defp write(context, data, name \\ "bridge.json") do
    path = Path.join(context.dir, name)
    File.write!(path, Jason.encode!(data))
    path
  end

  test "manifest defaults and explicit private adapter maps keep the complete declared contract", context do
    path =
      write(
        context,
        manifest(%{
          "capabilities" => ["text", "image", "text"],
          "adapters" => %{"webhook" => Atom.to_string(MockAdapter)}
        })
      )

    assert {:ok, %{registered_bridge_ids: [:checkpoint_bridge], degraded_diagnostics: []}} =
             BridgeRegistry.bootstrap_from_manifests(
               manifest_paths: [context.dir, Path.join(context.dir, "*.json"), path],
               required_bridges: ["checkpoint_bridge"]
             )

    assert %BridgePlugin{label: "Checkpoint Bridge", capabilities: [:text, :image], adapters: %{webhook: MockAdapter}} =
             BridgeRegistry.get_bridge(:checkpoint_bridge)

    assert {:ok, %{registered_bridge_ids: []}} = BridgeRegistry.bootstrap_from_manifests()
    assert BridgeRegistry.get_bridge(:checkpoint_bridge).capabilities == [:text, :image]
  end

  test "malformed manifest fields cannot replace an existing registered bridge", context do
    sentinel = BridgePlugin.from_adapter(MockAdapter)
    :ok = BridgeRegistry.register(sentinel)

    invalid = [
      {manifest(%{"manifest_version" => 2}), :unsupported_manifest_version},
      {Map.delete(manifest(), "manifest_version"), :invalid_manifest_schema},
      {manifest(%{"id" => 12}), :invalid_manifest_schema},
      {manifest(%{"adapter_module" => 12}), :invalid_manifest_schema},
      {manifest(%{"label" => ""}), :invalid_manifest_schema},
      {manifest(%{"capabilities" => "text"}), :invalid_manifest_schema},
      {manifest(%{"capabilities" => ["text", 12]}), :invalid_manifest_schema},
      {manifest(%{"adapters" => []}), :invalid_manifest_schema},
      {manifest(%{"adapters" => %{"webhook" => 12}}), :invalid_manifest_schema}
    ]

    for {data, type} <- invalid do
      path = write(context, data)

      assert {:ok, %{registered_bridge_ids: [], degraded_diagnostics: [%{type: ^type}]}} =
               BridgeRegistry.bootstrap_from_manifests(manifest_paths: [path])

      assert BridgeRegistry.list_bridges() == [sentinel]
    end
  end

  test "invalid bootstrap policy and missing required bridges preserve prior registration", context do
    sentinel = BridgePlugin.from_adapter(MockAdapter)
    :ok = BridgeRegistry.register(sentinel)

    for opts <- [[required_bridges: [12]], [collision_policy: :invalid]] do
      assert {:error, {:fatal_required_bridge_error, %{type: :invalid_bootstrap_config}}} =
               BridgeRegistry.bootstrap_from_manifests(opts ++ [clear_existing?: true])

      assert BridgeRegistry.list_bridges() == [sentinel]
    end

    path = write(context, manifest())

    assert {:error,
            {:fatal_required_bridge_error,
             %{type: :required_bridge_missing, reason: {:required_bridges_missing, [:absent]}}}} =
             BridgeRegistry.bootstrap_from_manifests(
               manifest_paths: [path],
               required_bridges: [:absent],
               clear_existing?: true
             )

    assert BridgeRegistry.list_bridges() == [sentinel]
  end

  test "private capability and verification hooks have explicit defaults" do
    assert AdapterBridge.channel_type(PreferredCapabilities) == :preferred_capabilities
    assert AdapterBridge.capabilities(PreferredCapabilities) == [:text, :image]
    assert AdapterBridge.supports?(PreferredCapabilities, :image)
    refute AdapterBridge.supports?(PreferredCapabilities, :streaming)
    refute AdapterBridge.supports?(PreferredCapabilities, nil)
    assert {:error, :unverified_sender} = AdapterBridge.verify_sender(PreferredCapabilities, %{}, %{})
    assert :ok = AdapterBridge.verify_sender(MockAdapter, %{}, %{})

    assert {:ok, %{text: "complete", format: :plain}} =
             AdapterBridge.sanitize_outbound(PreferredCapabilities, %{text: "complete"}, format: :plain)

    assert {:ok, %{text: "complete"}} = AdapterBridge.sanitize_outbound(MockAdapter, %{text: "complete"})
  end

  test "transport failures retain the retry policy while policy and input failures cannot retry" do
    recoverable = [
      :timeout,
      {:timeout, :socket},
      :econnrefused,
      :closed,
      :nxdomain,
      :network_error,
      {:network_error, :socket},
      {:api_error, :timeout},
      {:api_error, :closed},
      {:task_exit, :shutdown},
      {:exception, :transport},
      {:http_error, 503},
      {:http_status, 500},
      {:rate_limited, 1}
    ]

    degraded = [
      :unsupported,
      {:unsupported, :operation},
      {:unsupported_method, :query},
      {:media_policy_denied, :size},
      {:policy_denied, :scope, :action, :reason}
    ]

    fatal = [
      {:invalid_return, :malformed},
      {:invalid_request, :malformed},
      {:unsupported_operation, :malformed},
      {:http_error, 400},
      :unknown
    ]

    for reason <- recoverable do
      assert AdapterBridge.classify_failure(reason) == :recoverable
      assert AdapterBridge.failure_disposition(%{reason: reason}) == :retry
    end

    for reason <- degraded, do: assert(AdapterBridge.failure_disposition(reason) == :degrade)
    for reason <- fatal, do: assert(AdapterBridge.failure_disposition(reason) == :crash)
  end

  test "private operation defaults reject missing bindings without invoking a provider" do
    transport = start_supervised!(MockTransport)
    assert {:ok, binding} = Jido.Chat.bind(MockAdapter, id: "checkpoint-bridge", transport: transport)
    assert {:error, %{code: :invalid_binding}} = AdapterBridge.send_message(MockAdapter, "room", "complete")
    assert {:error, %{code: :invalid_binding}} = AdapterBridge.edit_message(MockAdapter, "room", "message", "complete")
    assert {:error, %{code: :invalid_binding}} = AdapterBridge.mark_as_read(MockAdapter, "room", "message")
    assert MockTransport.calls(transport) == []

    assert {:ok, result} =
             AdapterBridge.send_message(MockAdapter, "room", "complete", binding: binding, request_id: "one-send")

    assert result[:message_id] == "mock-message-1"

    assert {:ok, ^result} =
             AdapterBridge.send_message(MockAdapter, "room", "complete", binding: binding, request_id: "one-send")

    assert length(MockTransport.calls(transport)) == 1
  end
end
