defmodule Jido.Messaging.BridgePluginTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.BridgePlugin

  defmodule TestChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :test_channel

    @impl true
    def capabilities, do: [:text, :image, :streaming]

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule BasicChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :basic

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule TestMentionsAdapter do
  end

  defmodule SomeThreadingAdapter do
  end

  describe "from_adapter/2" do
    test "creates plugin from adapter module with capabilities" do
      plugin = BridgePlugin.from_adapter(TestChannel)

      assert plugin.id == :test_channel
      assert plugin.adapter_module == TestChannel
      assert plugin.label == "Test Channel"
      assert plugin.capabilities == [:text, :image, :streaming]
      assert plugin.adapters == %{}
    end

    test "creates plugin from adapter without capabilities callback" do
      plugin = BridgePlugin.from_adapter(BasicChannel)

      assert plugin.id == :basic
      assert plugin.adapter_module == BasicChannel
      assert plugin.label == "Basic"
      assert :text in plugin.capabilities
      assert :streaming in plugin.capabilities
      assert :threads in plugin.capabilities
    end

    test "allows overriding id" do
      plugin = BridgePlugin.from_adapter(TestChannel, id: :custom_id)
      assert plugin.id == :custom_id
    end

    test "allows overriding label" do
      plugin = BridgePlugin.from_adapter(TestChannel, label: "Custom Label")
      assert plugin.label == "Custom Label"
    end

    test "allows specifying adapters" do
      adapters = %{mentions: TestMentionsAdapter, threading: SomeThreadingAdapter}
      plugin = BridgePlugin.from_adapter(TestChannel, adapters: adapters)

      assert plugin.adapters == adapters
    end
  end

  describe "has_capability?/2" do
    test "returns true for supported capability" do
      plugin = BridgePlugin.from_adapter(TestChannel)

      assert BridgePlugin.has_capability?(plugin, :text)
      assert BridgePlugin.has_capability?(plugin, :streaming)
    end

    test "returns false for unsupported capability" do
      plugin = BridgePlugin.from_adapter(TestChannel)

      refute BridgePlugin.has_capability?(plugin, :video)
      refute BridgePlugin.has_capability?(plugin, :reactions)
    end
  end

  describe "get_adapter/2" do
    test "returns adapter module when present" do
      plugin = BridgePlugin.from_adapter(TestChannel, adapters: %{mentions: TestMentionsAdapter})

      assert BridgePlugin.get_adapter(plugin, :mentions) == TestMentionsAdapter
    end

    test "returns nil when adapter not present" do
      plugin = BridgePlugin.from_adapter(TestChannel)

      assert BridgePlugin.get_adapter(plugin, :mentions) == nil
      assert BridgePlugin.get_adapter(plugin, :threading) == nil
    end
  end

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = BridgePlugin.schema()
      assert is_struct(schema)
    end
  end
end
