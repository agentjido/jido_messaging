defmodule JidoMessaging.Channels.DiscordTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channels.Discord

  describe "channel_type/0" do
    test "returns :discord" do
      assert Discord.channel_type() == :discord
    end
  end

  describe "transform_incoming/1 with Nostrum.Struct.Message" do
    test "transforms guild message with full author info" do
      msg =
        build_nostrum_message(%{
          id: 111_222_333_444_555_666,
          channel_id: 123_456_789_012_345_678,
          content: "Hello bot!",
          timestamp: ~U[2024-01-31 12:00:00.000000Z],
          guild_id: 999_888_777_666_555_444,
          author: %{
            id: 987_654_321_098_765_432,
            username: "john_doe",
            global_name: "John"
          }
        })

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_room_id == 123_456_789_012_345_678
      assert incoming.external_user_id == 987_654_321_098_765_432
      assert incoming.text == "Hello bot!"
      assert incoming.username == "john_doe"
      assert incoming.display_name == "John"
      assert incoming.external_message_id == 111_222_333_444_555_666
      assert incoming.timestamp == ~U[2024-01-31 12:00:00.000000Z]
      assert incoming.chat_type == :guild
      assert incoming.chat_title == nil
    end

    test "transforms DM message (guild_id is nil)" do
      msg =
        build_nostrum_message(%{
          id: 111,
          channel_id: 222,
          content: "DM message",
          timestamp: ~U[2024-01-31 12:00:00.000000Z],
          guild_id: nil,
          author: %{id: 333, username: "dm_user", global_name: nil}
        })

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end

    test "uses username as display_name when global_name is nil" do
      msg =
        build_nostrum_message(%{
          id: 1,
          channel_id: 2,
          content: "test",
          timestamp: nil,
          guild_id: nil,
          author: %{id: 3, username: "fallback_user", global_name: nil}
        })

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.display_name == "fallback_user"
    end

    test "handles message without author" do
      msg =
        build_nostrum_message(%{
          id: 1,
          channel_id: 2,
          content: "No author message",
          timestamp: nil,
          guild_id: nil,
          author: nil
        })

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_user_id == nil
      assert incoming.username == nil
      assert incoming.display_name == nil
    end

    test "handles message without content" do
      msg =
        build_nostrum_message(%{
          id: 1,
          channel_id: 2,
          content: nil,
          timestamp: nil,
          guild_id: 3,
          author: %{id: 4, username: "user", global_name: "User"}
        })

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.text == nil
    end

    test "extracts attachment media into normalized media payloads" do
      msg =
        build_nostrum_message(%{
          id: 1,
          channel_id: 2,
          content: nil,
          timestamp: ~U[2024-01-31 12:00:00.000000Z],
          guild_id: 3,
          author: %{id: 4, username: "user", global_name: "User"}
        })

      msg =
        Map.put(msg, :attachments, [
          %{
            id: 9,
            url: "https://cdn.discordapp.com/file.png",
            filename: "file.png",
            content_type: "image/png",
            size: 256,
            width: 128,
            height: 128
          }
        ])

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert [%{kind: :image, url: "https://cdn.discordapp.com/file.png", media_type: "image/png"}] = incoming.media
    end
  end

  describe "transform_incoming/1 with atom key maps" do
    test "transforms map with atom keys" do
      msg = %{
        id: 111,
        channel_id: 222,
        content: "Atom key message",
        timestamp: ~U[2024-01-31 12:00:00.000000Z],
        guild_id: 333,
        author: %{
          id: 444,
          username: "atom_user",
          global_name: "Atom User"
        }
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_room_id == 222
      assert incoming.external_user_id == 444
      assert incoming.text == "Atom key message"
      assert incoming.username == "atom_user"
      assert incoming.display_name == "Atom User"
      assert incoming.external_message_id == 111
      assert incoming.timestamp == ~U[2024-01-31 12:00:00.000000Z]
      assert incoming.chat_type == :guild
    end

    test "handles atom key map without author" do
      msg = %{
        id: 1,
        channel_id: 2,
        content: "No author",
        timestamp: nil,
        guild_id: nil
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_user_id == nil
      assert incoming.username == nil
      assert incoming.display_name == nil
      assert incoming.chat_type == :dm
    end

    test "handles atom key map with nil guild_id (DM)" do
      msg = %{
        channel_id: 123,
        guild_id: nil,
        content: "DM"
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end

    test "handles atom key map with guild_id (guild)" do
      msg = %{
        channel_id: 123,
        guild_id: 456,
        content: "Guild"
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :guild
    end
  end

  describe "transform_incoming/1 with string key maps" do
    test "transforms map with string keys" do
      msg = %{
        "id" => 111,
        "channel_id" => 222,
        "content" => "String key message",
        "timestamp" => ~U[2024-01-31 12:00:00.000000Z],
        "guild_id" => 333,
        "author" => %{
          "id" => 444,
          "username" => "string_user",
          "global_name" => "String User"
        }
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_room_id == 222
      assert incoming.external_user_id == 444
      assert incoming.text == "String key message"
      assert incoming.username == "string_user"
      assert incoming.display_name == "String User"
      assert incoming.external_message_id == 111
      assert incoming.timestamp == ~U[2024-01-31 12:00:00.000000Z]
      assert incoming.chat_type == :guild
    end

    test "handles string key map without author" do
      msg = %{
        "id" => 1,
        "channel_id" => 2,
        "content" => "No author",
        "timestamp" => nil,
        "guild_id" => nil
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_user_id == nil
      assert incoming.username == nil
      assert incoming.display_name == nil
      assert incoming.chat_type == :dm
    end

    test "handles string key map with nil guild_id (DM)" do
      msg = %{
        "channel_id" => 123,
        "guild_id" => nil,
        "content" => "DM"
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end

    test "handles string key map with guild_id (guild)" do
      msg = %{
        "channel_id" => 123,
        "guild_id" => 456,
        "content" => "Guild"
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :guild
    end

    test "uses username as display_name when global_name is nil (string keys)" do
      msg = %{
        "channel_id" => 1,
        "author" => %{
          "id" => 2,
          "username" => "fallback",
          "global_name" => nil
        }
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.display_name == "fallback"
    end
  end

  describe "transform_incoming/1 with mixed key maps" do
    test "handles author with string keys in atom key map" do
      msg = %{
        channel_id: 123,
        id: 456,
        content: "Mixed",
        author: %{
          "id" => 789,
          "username" => "mixed_user",
          "global_name" => "Mixed User"
        }
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_user_id == 789
      assert incoming.username == "mixed_user"
      assert incoming.display_name == "Mixed User"
    end

    test "handles author with atom keys in string key map" do
      msg = %{
        "channel_id" => 123,
        "id" => 456,
        "content" => "Mixed",
        "author" => %{
          id: 789,
          username: "mixed_user",
          global_name: "Mixed User"
        }
      }

      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.external_user_id == 789
      assert incoming.username == "mixed_user"
      assert incoming.display_name == "Mixed User"
    end
  end

  describe "transform_incoming/1 error cases" do
    test "returns error for unsupported message type - string" do
      assert {:error, :unsupported_message_type} = Discord.transform_incoming("invalid")
    end

    test "returns error for unsupported message type - integer" do
      assert {:error, :unsupported_message_type} = Discord.transform_incoming(123)
    end

    test "returns error for unsupported message type - list" do
      assert {:error, :unsupported_message_type} = Discord.transform_incoming([1, 2, 3])
    end

    test "returns error for unsupported message type - nil" do
      assert {:error, :unsupported_message_type} = Discord.transform_incoming(nil)
    end

    test "returns error for map without channel_id" do
      msg = %{id: 1, content: "No channel_id"}
      assert {:error, :unsupported_message_type} = Discord.transform_incoming(msg)
    end
  end

  describe "transform_incoming/1 chat_type determination" do
    test "returns :guild when guild_id is present (atom key)" do
      msg = %{channel_id: 1, guild_id: 123}
      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :guild
    end

    test "returns :dm when guild_id is nil (atom key)" do
      msg = %{channel_id: 1, guild_id: nil}
      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end

    test "returns :dm when guild_id is missing (atom key)" do
      msg = %{channel_id: 1}
      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end

    test "returns :guild when guild_id is present (string key)" do
      msg = %{"channel_id" => 1, "guild_id" => 123}
      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :guild
    end

    test "returns :dm when guild_id is nil (string key)" do
      msg = %{"channel_id" => 1, "guild_id" => nil}
      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end

    test "returns :dm when guild_id is missing (string key)" do
      msg = %{"channel_id" => 1}
      assert {:ok, incoming} = Discord.transform_incoming(msg)
      assert incoming.chat_type == :dm
    end
  end

  # Helper to build a mock Nostrum.Struct.Message
  # Since Nostrum is runtime: false, we create a struct that matches the pattern
  defp build_nostrum_message(attrs) do
    author =
      case attrs[:author] do
        nil -> nil
        author_attrs -> struct!(Nostrum.Struct.User, author_attrs)
      end

    struct!(Nostrum.Struct.Message, %{
      id: attrs[:id],
      channel_id: attrs[:channel_id],
      content: attrs[:content],
      timestamp: attrs[:timestamp],
      guild_id: attrs[:guild_id],
      author: author
    })
  end
end
