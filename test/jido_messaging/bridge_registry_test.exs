defmodule Jido.Messaging.BridgeRegistryTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{BridgePlugin, BridgeRegistry}

  defmodule TelegramChannel do
    @behaviour Jido.Chat.Adapter

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
    @behaviour Jido.Chat.Adapter

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
  end

  setup do
    BridgeRegistry.clear()
    :ok
  end

  describe "register/1" do
    test "registers a plugin" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      assert BridgeRegistry.register(plugin) == :ok
    end

    test "replaces existing plugin with same id" do
      plugin1 = BridgePlugin.from_adapter(TelegramChannel, label: "First")
      plugin2 = BridgePlugin.from_adapter(TelegramChannel, label: "Second")

      BridgeRegistry.register(plugin1)
      BridgeRegistry.register(plugin2)

      result = BridgeRegistry.get_bridge(:telegram)
      assert result.label == "Second"
    end
  end

  describe "unregister/1" do
    test "removes a registered plugin" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      assert BridgeRegistry.get_bridge(:telegram) != nil

      BridgeRegistry.unregister(:telegram)

      assert BridgeRegistry.get_bridge(:telegram) == nil
    end

    test "succeeds even if plugin doesn't exist" do
      assert BridgeRegistry.unregister(:nonexistent) == :ok
    end
  end

  describe "list_bridges/0" do
    test "returns empty list when no plugins registered" do
      assert BridgeRegistry.list_bridges() == []
    end

    test "returns all registered plugins" do
      telegram = BridgePlugin.from_adapter(TelegramChannel)
      discord = BridgePlugin.from_adapter(DiscordChannel)

      BridgeRegistry.register(telegram)
      BridgeRegistry.register(discord)

      plugins = BridgeRegistry.list_bridges()
      ids = Enum.map(plugins, & &1.id)

      assert length(plugins) == 2
      assert :telegram in ids
      assert :discord in ids
    end
  end

  describe "get_bridge/1" do
    test "returns plugin when registered" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      result = BridgeRegistry.get_bridge(:telegram)

      assert result.id == :telegram
      assert result.adapter_module == TelegramChannel
    end

    test "returns nil when not registered" do
      assert BridgeRegistry.get_bridge(:nonexistent) == nil
    end
  end

  describe "get_bridge!/1" do
    test "returns plugin when registered" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      result = BridgeRegistry.get_bridge!(:telegram)
      assert result.id == :telegram
    end

    test "raises KeyError when not registered" do
      assert_raise KeyError, ~r/bridge not found/, fn ->
        BridgeRegistry.get_bridge!(:nonexistent)
      end
    end
  end

  describe "capabilities/1" do
    test "returns capabilities for registered channel" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      caps = BridgeRegistry.capabilities(:telegram)
      assert :text in caps
      assert :image in caps
      assert :streaming in caps
    end

    test "returns empty list for unregistered channel" do
      assert BridgeRegistry.capabilities(:nonexistent) == []
    end
  end

  describe "has_capability?/2" do
    test "returns true for supported capability" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      assert BridgeRegistry.has_capability?(:telegram, :streaming)
    end

    test "returns false for unsupported capability" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      refute BridgeRegistry.has_capability?(:telegram, :threads)
    end

    test "returns false for unregistered channel" do
      refute BridgeRegistry.has_capability?(:nonexistent, :text)
    end
  end

  describe "get_adapter_module/1" do
    test "returns module for registered channel" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      assert BridgeRegistry.get_adapter_module(:telegram) == TelegramChannel
    end

    test "returns nil for unregistered channel" do
      assert BridgeRegistry.get_adapter_module(:nonexistent) == nil
    end
  end

  describe "get_adapter/2" do
    test "returns adapter for registered channel with adapter" do
      plugin = BridgePlugin.from_adapter(TelegramChannel, adapters: %{mentions: TestMentionsAdapter})
      BridgeRegistry.register(plugin)

      assert BridgeRegistry.get_adapter(:telegram, :mentions) == TestMentionsAdapter
    end

    test "returns nil for registered channel without adapter" do
      plugin = BridgePlugin.from_adapter(TelegramChannel)
      BridgeRegistry.register(plugin)

      assert BridgeRegistry.get_adapter(:telegram, :mentions) == nil
    end

    test "returns nil for unregistered channel" do
      assert BridgeRegistry.get_adapter(:nonexistent, :mentions) == nil
    end
  end

  describe "list_channel_types/0" do
    test "returns empty list when no plugins registered" do
      assert BridgeRegistry.list_channel_types() == []
    end

    test "returns all registered channel types" do
      BridgeRegistry.register(BridgePlugin.from_adapter(TelegramChannel))
      BridgeRegistry.register(BridgePlugin.from_adapter(DiscordChannel))

      types = BridgeRegistry.list_channel_types()

      assert :telegram in types
      assert :discord in types
    end
  end

  describe "clear/0" do
    test "removes all registered plugins" do
      BridgeRegistry.register(BridgePlugin.from_adapter(TelegramChannel))
      BridgeRegistry.register(BridgePlugin.from_adapter(DiscordChannel))

      assert length(BridgeRegistry.list_bridges()) == 2

      BridgeRegistry.clear()

      assert BridgeRegistry.list_bridges() == []
    end

    test "remains safe under concurrent calls" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> BridgeRegistry.clear() end)
        end

      results = Enum.map(tasks, &Task.await(&1, 1_000))
      assert Enum.all?(results, &(&1 == :ok))
      assert BridgeRegistry.list_bridges() == []
    end
  end
end
