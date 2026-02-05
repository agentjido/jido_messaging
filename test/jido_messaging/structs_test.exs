defmodule JidoMessaging.StructsTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.{Message, Room, Participant, Instance}
  alias JidoMessaging.Content.{Text, ToolUse, ToolResult, Image, File, Audio, Video}

  describe "Message" do
    test "new/1 creates message with defaults" do
      message =
        Message.new(%{
          room_id: "room_1",
          sender_id: "user_1",
          role: :user
        })

      assert Jido.Signal.ID.valid?(message.id)
      assert message.room_id == "room_1"
      assert message.role == :user
      assert message.content == []
      assert message.status == :sending
      assert message.metadata == %{}
      assert %DateTime{} = message.inserted_at
      assert %DateTime{} = message.updated_at
    end

    test "new/1 creates message with threading fields" do
      message =
        Message.new(%{
          room_id: "room_1",
          sender_id: "user_1",
          role: :user,
          reply_to_id: "msg_prev",
          external_reply_to_id: "ext_prev",
          thread_root_id: "thread_root_123",
          external_thread_id: "ext_thread_456"
        })

      assert message.reply_to_id == "msg_prev"
      assert message.external_reply_to_id == "ext_prev"
      assert message.thread_root_id == "thread_root_123"
      assert message.external_thread_id == "ext_thread_456"
    end

    test "schema/0 returns Zoi schema" do
      schema = Message.schema()
      assert is_map(schema)
    end
  end

  describe "Room" do
    test "new/1 creates room with defaults" do
      room = Room.new(%{type: :direct})

      assert Jido.Signal.ID.valid?(room.id)
      assert room.type == :direct
      assert room.name == nil
      assert room.external_bindings == %{}
      assert room.metadata == %{}
      assert %DateTime{} = room.inserted_at
    end

    test "schema/0 returns Zoi schema" do
      schema = Room.schema()
      assert is_map(schema)
    end
  end

  describe "Participant" do
    test "new/1 creates participant with defaults" do
      participant = Participant.new(%{type: :human})

      assert Jido.Signal.ID.valid?(participant.id)
      assert participant.type == :human
      assert participant.identity == %{}
      assert participant.external_ids == %{}
      assert participant.presence == :offline
      assert participant.metadata == %{}
    end

    test "schema/0 returns Zoi schema" do
      schema = Participant.schema()
      assert is_map(schema)
    end
  end

  describe "Instance" do
    test "new/1 creates instance with defaults" do
      instance =
        Instance.new(%{
          name: "my_bot",
          channel_type: :telegram
        })

      assert Jido.Signal.ID.valid?(instance.id)
      assert instance.name == "my_bot"
      assert instance.channel_type == :telegram
      assert instance.status == :disconnected
      assert instance.credentials == %{}
      assert instance.settings == %{}
      assert %DateTime{} = instance.inserted_at
    end

    test "schema/0 returns Zoi schema" do
      schema = Instance.schema()
      assert is_map(schema)
    end
  end

  describe "Content.Text" do
    test "new/1 creates text content" do
      text = Text.new("Hello, world!")

      assert text.type == :text
      assert text.text == "Hello, world!"
    end

    test "schema/0 returns Zoi schema" do
      schema = Text.schema()
      assert is_map(schema)
    end
  end

  describe "Content.ToolUse" do
    test "new/3 creates tool use content with input" do
      tool_use = ToolUse.new("call_123", "get_weather", %{location: "San Francisco"})

      assert tool_use.type == :tool_use
      assert tool_use.id == "call_123"
      assert tool_use.name == "get_weather"
      assert tool_use.input == %{location: "San Francisco"}
    end

    test "new/2 creates tool use content with empty input" do
      tool_use = ToolUse.new("call_456", "list_files")

      assert tool_use.type == :tool_use
      assert tool_use.id == "call_456"
      assert tool_use.name == "list_files"
      assert tool_use.input == %{}
    end

    test "schema/0 returns Zoi schema" do
      schema = ToolUse.schema()
      assert is_map(schema)
    end
  end

  describe "Content.ToolResult" do
    test "new/2 creates tool result content with string" do
      result = ToolResult.new("call_123", "The weather is 72°F")

      assert result.type == :tool_result
      assert result.tool_use_id == "call_123"
      assert result.content == "The weather is 72°F"
      assert result.is_error == false
    end

    test "new/2 creates tool result content with map" do
      result = ToolResult.new("call_456", %{files: ["a.txt", "b.txt"], count: 2})

      assert result.type == :tool_result
      assert result.tool_use_id == "call_456"
      assert result.content == %{files: ["a.txt", "b.txt"], count: 2}
      assert result.is_error == false
    end

    test "new/3 creates error result" do
      result = ToolResult.new("call_789", "Tool not found: unknown_tool", true)

      assert result.type == :tool_result
      assert result.tool_use_id == "call_789"
      assert result.content == "Tool not found: unknown_tool"
      assert result.is_error == true
    end

    test "schema/0 returns Zoi schema" do
      schema = ToolResult.schema()
      assert is_map(schema)
    end
  end

  describe "Content.Image" do
    test "new/1 creates image from URL" do
      image = Image.new("https://example.com/photo.jpg")

      assert image.type == :image
      assert image.url == "https://example.com/photo.jpg"
      assert image.data == nil
      assert image.media_type == nil
    end

    test "new/2 creates image with options" do
      image =
        Image.new("https://example.com/photo.jpg",
          media_type: "image/jpeg",
          alt_text: "A photo",
          width: 800,
          height: 600
        )

      assert image.type == :image
      assert image.url == "https://example.com/photo.jpg"
      assert image.media_type == "image/jpeg"
      assert image.alt_text == "A photo"
      assert image.width == 800
      assert image.height == 600
    end

    test "from_base64/3 creates image from base64 data" do
      image = Image.from_base64("base64data==", "image/png", alt_text: "Test image")

      assert image.type == :image
      assert image.url == nil
      assert image.data == "base64data=="
      assert image.media_type == "image/png"
      assert image.alt_text == "Test image"
    end

    test "schema/0 returns Zoi schema" do
      schema = Image.schema()
      assert is_map(schema)
    end
  end

  describe "Content.File" do
    test "new/2 creates file from URL" do
      file = File.new("https://example.com/doc.pdf", "document.pdf")

      assert file.type == :file
      assert file.url == "https://example.com/doc.pdf"
      assert file.filename == "document.pdf"
      assert file.data == nil
    end

    test "new/3 creates file with options" do
      file =
        File.new("https://example.com/doc.pdf", "document.pdf",
          media_type: "application/pdf",
          size: 1024
        )

      assert file.type == :file
      assert file.url == "https://example.com/doc.pdf"
      assert file.filename == "document.pdf"
      assert file.media_type == "application/pdf"
      assert file.size == 1024
    end

    test "from_base64/4 creates file from base64 data" do
      file = File.from_base64("base64data==", "report.pdf", "application/pdf", size: 2048)

      assert file.type == :file
      assert file.url == nil
      assert file.data == "base64data=="
      assert file.filename == "report.pdf"
      assert file.media_type == "application/pdf"
      assert file.size == 2048
    end

    test "from_base64/3 creates file without size option" do
      file = File.from_base64("base64data==", "report.pdf", "application/pdf")

      assert file.type == :file
      assert file.data == "base64data=="
      assert file.filename == "report.pdf"
      assert file.media_type == "application/pdf"
      assert file.size == nil
    end

    test "schema/0 returns Zoi schema" do
      schema = File.schema()
      assert is_map(schema)
    end
  end

  describe "Content.Audio" do
    test "new/1 creates audio from URL" do
      audio = Audio.new("https://example.com/voice.ogg")

      assert audio.type == :audio
      assert audio.url == "https://example.com/voice.ogg"
      assert audio.data == nil
    end

    test "new/2 creates audio with options" do
      audio =
        Audio.new("https://example.com/voice.ogg",
          media_type: "audio/ogg",
          duration: 15,
          transcript: "Hello world"
        )

      assert audio.type == :audio
      assert audio.url == "https://example.com/voice.ogg"
      assert audio.media_type == "audio/ogg"
      assert audio.duration == 15
      assert audio.transcript == "Hello world"
    end

    test "from_base64/3 creates audio from base64 data" do
      audio = Audio.from_base64("base64data==", "audio/mp3", duration: 30)

      assert audio.type == :audio
      assert audio.url == nil
      assert audio.data == "base64data=="
      assert audio.media_type == "audio/mp3"
      assert audio.duration == 30
    end

    test "schema/0 returns Zoi schema" do
      schema = Audio.schema()
      assert is_map(schema)
    end
  end

  describe "Content.Video" do
    test "new/1 creates video from URL" do
      video = Video.new("https://example.com/clip.mp4")

      assert video.type == :video
      assert video.url == "https://example.com/clip.mp4"
      assert video.data == nil
    end

    test "new/2 creates video with options" do
      video =
        Video.new("https://example.com/clip.mp4",
          media_type: "video/mp4",
          duration: 60,
          width: 1920,
          height: 1080,
          thumbnail_url: "https://example.com/thumb.jpg"
        )

      assert video.type == :video
      assert video.url == "https://example.com/clip.mp4"
      assert video.media_type == "video/mp4"
      assert video.duration == 60
      assert video.width == 1920
      assert video.height == 1080
      assert video.thumbnail_url == "https://example.com/thumb.jpg"
    end

    test "from_base64/3 creates video from base64 data" do
      video = Video.from_base64("base64data==", "video/mp4", duration: 120)

      assert video.type == :video
      assert video.url == nil
      assert video.data == "base64data=="
      assert video.media_type == "video/mp4"
      assert video.duration == 120
    end

    test "schema/0 returns Zoi schema" do
      schema = Video.schema()
      assert is_map(schema)
    end
  end
end
