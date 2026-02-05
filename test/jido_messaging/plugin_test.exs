defmodule JidoMessaging.PluginTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Plugin

  defmodule TestChannel do
    @behaviour JidoMessaging.Channel

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
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :basic

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule TestMentionsAdapter do
    @behaviour JidoMessaging.Adapters.Mentions

    @impl true
    def parse_mentions(_body, _raw), do: []

    @impl true
    def was_mentioned?(_raw, _bot_id), do: false
  end

  describe "from_channel/2" do
    test "creates plugin from channel module with capabilities" do
      plugin = Plugin.from_channel(TestChannel)

      assert plugin.id == :test_channel
      assert plugin.channel_module == TestChannel
      assert plugin.label == "Test Channel"
      assert plugin.capabilities == [:text, :image, :streaming]
      assert plugin.adapters == %{}
    end

    test "creates plugin from channel without capabilities callback" do
      plugin = Plugin.from_channel(BasicChannel)

      assert plugin.id == :basic
      assert plugin.channel_module == BasicChannel
      assert plugin.label == "Basic"
      assert plugin.capabilities == [:text]
    end

    test "allows overriding id" do
      plugin = Plugin.from_channel(TestChannel, id: :custom_id)
      assert plugin.id == :custom_id
    end

    test "allows overriding label" do
      plugin = Plugin.from_channel(TestChannel, label: "Custom Label")
      assert plugin.label == "Custom Label"
    end

    test "allows specifying adapters" do
      adapters = %{mentions: TestMentionsAdapter, threading: SomeThreadingAdapter}
      plugin = Plugin.from_channel(TestChannel, adapters: adapters)

      assert plugin.adapters == adapters
    end
  end

  describe "has_capability?/2" do
    test "returns true for supported capability" do
      plugin = Plugin.from_channel(TestChannel)

      assert Plugin.has_capability?(plugin, :text)
      assert Plugin.has_capability?(plugin, :image)
      assert Plugin.has_capability?(plugin, :streaming)
    end

    test "returns false for unsupported capability" do
      plugin = Plugin.from_channel(TestChannel)

      refute Plugin.has_capability?(plugin, :video)
      refute Plugin.has_capability?(plugin, :reactions)
    end
  end

  describe "get_adapter/2" do
    test "returns adapter module when present" do
      plugin = Plugin.from_channel(TestChannel, adapters: %{mentions: TestMentionsAdapter})

      assert Plugin.get_adapter(plugin, :mentions) == TestMentionsAdapter
    end

    test "returns nil when adapter not present" do
      plugin = Plugin.from_channel(TestChannel)

      assert Plugin.get_adapter(plugin, :mentions) == nil
      assert Plugin.get_adapter(plugin, :threading) == nil
    end
  end

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = Plugin.schema()
      assert is_struct(schema)
    end
  end
end
