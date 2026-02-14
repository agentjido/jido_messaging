defmodule JidoMessaging.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Capabilities
  alias JidoMessaging.Content.{Text, Image, Audio, Video, File, ToolUse, ToolResult}

  describe "supports?/2" do
    test "returns true when capability is in list" do
      assert Capabilities.supports?([:text, :image], :text)
      assert Capabilities.supports?([:text, :image], :image)
    end

    test "returns false when capability is not in list" do
      refute Capabilities.supports?([:text], :image)
      refute Capabilities.supports?([], :text)
    end
  end

  describe "content_requires/1" do
    test "returns [:text] for Text content" do
      assert Capabilities.content_requires(%Text{text: "hello"}) == [:text]
    end

    test "returns [:image] for Image content" do
      assert Capabilities.content_requires(%Image{url: "https://example.com/img.png"}) == [:image]
    end

    test "returns [:audio] for Audio content" do
      assert Capabilities.content_requires(%Audio{url: "https://example.com/audio.mp3"}) == [:audio]
    end

    test "returns [:video] for Video content" do
      assert Capabilities.content_requires(%Video{url: "https://example.com/video.mp4"}) == [:video]
    end

    test "returns [:file] for File content" do
      assert Capabilities.content_requires(%File{url: "https://example.com/doc.pdf", filename: "doc.pdf"}) == [:file]
    end

    test "returns [:tool_use] for ToolUse content" do
      assert Capabilities.content_requires(%ToolUse{id: "1", name: "test"}) == [:tool_use]
    end

    test "returns [:text] for ToolResult content (tool results are text)" do
      assert Capabilities.content_requires(%ToolResult{tool_use_id: "1", content: "result"}) == [:text]
    end
  end

  describe "can_deliver?/2" do
    test "returns true when channel has required capability" do
      assert Capabilities.can_deliver?([:text, :image], %Text{text: "hello"})
      assert Capabilities.can_deliver?([:text, :image], %Image{url: "https://example.com/img.png"})
    end

    test "returns false when channel lacks required capability" do
      refute Capabilities.can_deliver?([:text], %Image{url: "https://example.com/img.png"})
      refute Capabilities.can_deliver?([:image], %Text{text: "hello"})
    end

    test "returns true for tool results with text capability" do
      assert Capabilities.can_deliver?([:text], %ToolResult{tool_use_id: "1", content: "result"})
    end

    test "returns false for tool_use without tool_use capability" do
      refute Capabilities.can_deliver?([:text], %ToolUse{id: "1", name: "test"})
    end
  end

  describe "filter_content/2" do
    test "filters out unsupported content" do
      content = [
        %Text{text: "Hello"},
        %Image{url: "https://example.com/img.png"},
        %Audio{url: "https://example.com/audio.mp3"}
      ]

      filtered = Capabilities.filter_content(content, [:text, :image])

      assert length(filtered) == 2
      assert Enum.any?(filtered, fn c -> match?(%Text{}, c) end)
      assert Enum.any?(filtered, fn c -> match?(%Image{}, c) end)
      refute Enum.any?(filtered, fn c -> match?(%Audio{}, c) end)
    end

    test "returns empty list when no content is supported" do
      content = [%Image{url: "https://example.com/img.png"}]
      assert Capabilities.filter_content(content, [:text]) == []
    end

    test "returns all content when all is supported" do
      content = [%Text{text: "Hello"}, %Image{url: "https://example.com/img.png"}]
      filtered = Capabilities.filter_content(content, [:text, :image, :audio])

      assert length(filtered) == 2
    end
  end

  describe "unsupported_content/2" do
    test "returns only unsupported content" do
      content = [
        %Text{text: "Hello"},
        %Image{url: "https://example.com/img.png"},
        %Audio{url: "https://example.com/audio.mp3"}
      ]

      unsupported = Capabilities.unsupported_content(content, [:text])

      assert length(unsupported) == 2
      assert Enum.any?(unsupported, fn c -> match?(%Image{}, c) end)
      assert Enum.any?(unsupported, fn c -> match?(%Audio{}, c) end)
      refute Enum.any?(unsupported, fn c -> match?(%Text{}, c) end)
    end

    test "returns empty list when all content is supported" do
      content = [%Text{text: "Hello"}]
      assert Capabilities.unsupported_content(content, [:text]) == []
    end
  end

  describe "channel_capabilities/1" do
    test "returns capabilities for Telegram channel" do
      caps = Capabilities.channel_capabilities(JidoMessaging.Channels.Telegram)
      assert :text in caps
      assert :image in caps
      assert :streaming in caps
      assert :message_edit in caps
    end

    test "returns capabilities for Discord channel" do
      caps = Capabilities.channel_capabilities(JidoMessaging.Channels.Discord)
      assert :text in caps
      assert :reactions in caps
      assert :threads in caps
      assert :message_edit in caps
    end

    test "returns capabilities for Slack channel" do
      caps = Capabilities.channel_capabilities(JidoMessaging.Channels.Slack)
      assert :text in caps
      assert :reactions in caps
      assert :threads in caps
      assert :message_edit in caps
      refute :audio in caps
    end

    test "returns capabilities for WhatsApp channel" do
      caps = Capabilities.channel_capabilities(JidoMessaging.Channels.WhatsApp)
      assert :text in caps
      assert :image in caps
      assert :audio in caps
      refute :message_edit in caps
      refute :reactions in caps
    end

    test "returns [:text] as default for channels without capabilities callback" do
      defmodule TestChannelWithoutCapabilities do
        @behaviour JidoMessaging.Channel

        @impl true
        def channel_type, do: :test

        @impl true
        def transform_incoming(_), do: {:error, :not_implemented}

        @impl true
        def send_message(_, _, _), do: {:error, :not_implemented}
      end

      assert Capabilities.channel_capabilities(TestChannelWithoutCapabilities) == [:text]
    end
  end

  describe "all/0" do
    test "returns all capability atoms" do
      all = Capabilities.all()

      assert :text in all
      assert :image in all
      assert :audio in all
      assert :video in all
      assert :file in all
      assert :tool_use in all
      assert :streaming in all
      assert :reactions in all
      assert :threads in all
      assert :listener_lifecycle in all
      assert :routing_metadata in all
      assert :sender_verification in all
      assert :outbound_sanitization in all
      assert :media_send in all
      assert :media_edit in all
      assert :command_hints in all
      assert :message_edit in all
    end
  end
end
