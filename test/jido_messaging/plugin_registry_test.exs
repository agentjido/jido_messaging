defmodule JidoMessaging.PluginRegistryTest do
  use ExUnit.Case, async: false

  alias JidoMessaging.{Plugin, PluginRegistry}

  defmodule TelegramChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :telegram

    @impl true
    def capabilities, do: [:text, :image, :streaming]

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule DiscordChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :discord

    @impl true
    def capabilities, do: [:text, :image, :reactions, :threads]

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

  setup do
    PluginRegistry.clear()
    :ok
  end

  describe "register/1" do
    test "registers a plugin" do
      plugin = Plugin.from_channel(TelegramChannel)
      assert PluginRegistry.register(plugin) == :ok
    end

    test "replaces existing plugin with same id" do
      plugin1 = Plugin.from_channel(TelegramChannel, label: "First")
      plugin2 = Plugin.from_channel(TelegramChannel, label: "Second")

      PluginRegistry.register(plugin1)
      PluginRegistry.register(plugin2)

      result = PluginRegistry.get_plugin(:telegram)
      assert result.label == "Second"
    end
  end

  describe "unregister/1" do
    test "removes a registered plugin" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      assert PluginRegistry.get_plugin(:telegram) != nil

      PluginRegistry.unregister(:telegram)

      assert PluginRegistry.get_plugin(:telegram) == nil
    end

    test "succeeds even if plugin doesn't exist" do
      assert PluginRegistry.unregister(:nonexistent) == :ok
    end
  end

  describe "list_plugins/0" do
    test "returns empty list when no plugins registered" do
      assert PluginRegistry.list_plugins() == []
    end

    test "returns all registered plugins" do
      telegram = Plugin.from_channel(TelegramChannel)
      discord = Plugin.from_channel(DiscordChannel)

      PluginRegistry.register(telegram)
      PluginRegistry.register(discord)

      plugins = PluginRegistry.list_plugins()
      ids = Enum.map(plugins, & &1.id)

      assert length(plugins) == 2
      assert :telegram in ids
      assert :discord in ids
    end
  end

  describe "get_plugin/1" do
    test "returns plugin when registered" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      result = PluginRegistry.get_plugin(:telegram)

      assert result.id == :telegram
      assert result.channel_module == TelegramChannel
    end

    test "returns nil when not registered" do
      assert PluginRegistry.get_plugin(:nonexistent) == nil
    end
  end

  describe "get_plugin!/1" do
    test "returns plugin when registered" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      result = PluginRegistry.get_plugin!(:telegram)
      assert result.id == :telegram
    end

    test "raises KeyError when not registered" do
      assert_raise KeyError, ~r/plugin not found/, fn ->
        PluginRegistry.get_plugin!(:nonexistent)
      end
    end
  end

  describe "capabilities/1" do
    test "returns capabilities for registered channel" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      caps = PluginRegistry.capabilities(:telegram)
      assert :text in caps
      assert :image in caps
      assert :streaming in caps
    end

    test "returns empty list for unregistered channel" do
      assert PluginRegistry.capabilities(:nonexistent) == []
    end
  end

  describe "has_capability?/2" do
    test "returns true for supported capability" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      assert PluginRegistry.has_capability?(:telegram, :streaming)
    end

    test "returns false for unsupported capability" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      refute PluginRegistry.has_capability?(:telegram, :threads)
    end

    test "returns false for unregistered channel" do
      refute PluginRegistry.has_capability?(:nonexistent, :text)
    end
  end

  describe "get_channel_module/1" do
    test "returns module for registered channel" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      assert PluginRegistry.get_channel_module(:telegram) == TelegramChannel
    end

    test "returns nil for unregistered channel" do
      assert PluginRegistry.get_channel_module(:nonexistent) == nil
    end
  end

  describe "get_adapter/2" do
    test "returns adapter for registered channel with adapter" do
      plugin = Plugin.from_channel(TelegramChannel, adapters: %{mentions: TestMentionsAdapter})
      PluginRegistry.register(plugin)

      assert PluginRegistry.get_adapter(:telegram, :mentions) == TestMentionsAdapter
    end

    test "returns nil for registered channel without adapter" do
      plugin = Plugin.from_channel(TelegramChannel)
      PluginRegistry.register(plugin)

      assert PluginRegistry.get_adapter(:telegram, :mentions) == nil
    end

    test "returns nil for unregistered channel" do
      assert PluginRegistry.get_adapter(:nonexistent, :mentions) == nil
    end
  end

  describe "list_channel_types/0" do
    test "returns empty list when no plugins registered" do
      assert PluginRegistry.list_channel_types() == []
    end

    test "returns all registered channel types" do
      PluginRegistry.register(Plugin.from_channel(TelegramChannel))
      PluginRegistry.register(Plugin.from_channel(DiscordChannel))

      types = PluginRegistry.list_channel_types()

      assert :telegram in types
      assert :discord in types
    end
  end

  describe "clear/0" do
    test "removes all registered plugins" do
      PluginRegistry.register(Plugin.from_channel(TelegramChannel))
      PluginRegistry.register(Plugin.from_channel(DiscordChannel))

      assert length(PluginRegistry.list_plugins()) == 2

      PluginRegistry.clear()

      assert PluginRegistry.list_plugins() == []
    end

    test "remains safe under concurrent calls" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> PluginRegistry.clear() end)
        end

      results = Enum.map(tasks, &Task.await(&1, 1_000))
      assert Enum.all?(results, &(&1 == :ok))
      assert PluginRegistry.list_plugins() == []
    end
  end
end
