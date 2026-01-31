defmodule JidoMessaging.Channels.TelegramTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channels.Telegram

  describe "channel_type/0" do
    test "returns :telegram" do
      assert Telegram.channel_type() == :telegram
    end
  end

  describe "transform_incoming/1 edge cases" do
    test "handles message without from field" do
      update = %Telegex.Type.Update{
        update_id: 123,
        message: %Telegex.Type.Message{
          message_id: 456,
          date: 1_706_745_600,
          chat: %Telegex.Type.Chat{id: 789, type: "private"},
          from: nil,
          text: "No sender"
        }
      }

      assert {:ok, incoming} = Telegram.transform_incoming(update)
      assert incoming.external_user_id == nil
      assert incoming.username == nil
      assert incoming.display_name == nil
    end

    test "handles message without text" do
      update = %Telegex.Type.Update{
        update_id: 123,
        message: %Telegex.Type.Message{
          message_id: 456,
          date: 1_706_745_600,
          chat: %Telegex.Type.Chat{id: 789, type: "private"},
          from: %Telegex.Type.User{id: 111, is_bot: false, first_name: "John"},
          text: nil
        }
      }

      assert {:ok, incoming} = Telegram.transform_incoming(update)
      assert incoming.text == nil
    end

    test "handles unknown chat type" do
      update = %Telegex.Type.Update{
        update_id: 123,
        message: %Telegex.Type.Message{
          message_id: 456,
          date: 1_706_745_600,
          chat: %Telegex.Type.Chat{id: 789, type: "unknown_type"},
          text: "test"
        }
      }

      assert {:ok, incoming} = Telegram.transform_incoming(update)
      assert incoming.chat_type == :unknown
    end

    test "handles atom chat types" do
      for type <- [:private, :group, :supergroup, :channel] do
        update = %Telegex.Type.Update{
          update_id: 1,
          message: %Telegex.Type.Message{
            message_id: 1,
            date: 0,
            chat: %Telegex.Type.Chat{id: 1, type: type},
            text: "test"
          }
        }

        {:ok, incoming} = Telegram.transform_incoming(update)
        assert incoming.chat_type == type
      end
    end

    test "handles map with missing nested fields" do
      update = %{
        "message" => %{
          "message_id" => 123,
          "date" => 1_706_745_600,
          "chat" => %{"id" => 456},
          "text" => "minimal"
        }
      }

      {:ok, incoming} = Telegram.transform_incoming(update)
      assert incoming.external_room_id == 456
      assert incoming.external_user_id == nil
      assert incoming.text == "minimal"
    end
  end

  describe "transform_incoming/1" do
    test "transforms Telegex.Type.Update with message" do
      update = %Telegex.Type.Update{
        update_id: 123,
        message: %Telegex.Type.Message{
          message_id: 456,
          date: 1_706_745_600,
          chat: %Telegex.Type.Chat{
            id: 789,
            type: "private",
            title: nil
          },
          from: %Telegex.Type.User{
            id: 111,
            is_bot: false,
            first_name: "John",
            username: "john_doe"
          },
          text: "Hello bot!"
        }
      }

      assert {:ok, incoming} = Telegram.transform_incoming(update)
      assert incoming.external_room_id == 789
      assert incoming.external_user_id == 111
      assert incoming.text == "Hello bot!"
      assert incoming.username == "john_doe"
      assert incoming.display_name == "John"
      assert incoming.external_message_id == 456
      assert incoming.timestamp == 1_706_745_600
      assert incoming.chat_type == :private
    end

    test "transforms map-based update (string keys)" do
      update = %{
        "message" => %{
          "message_id" => 456,
          "date" => 1_706_745_600,
          "chat" => %{
            "id" => 789,
            "type" => "group",
            "title" => "Test Group"
          },
          "from" => %{
            "id" => 111,
            "first_name" => "Jane",
            "username" => "jane_doe"
          },
          "text" => "Hello group!"
        }
      }

      assert {:ok, incoming} = Telegram.transform_incoming(update)
      assert incoming.external_room_id == 789
      assert incoming.external_user_id == 111
      assert incoming.text == "Hello group!"
      assert incoming.username == "jane_doe"
      assert incoming.display_name == "Jane"
      assert incoming.chat_type == :group
      assert incoming.chat_title == "Test Group"
    end

    test "returns error for update without message" do
      update = %Telegex.Type.Update{update_id: 123, message: nil}
      assert {:error, :no_message} = Telegram.transform_incoming(update)
    end

    test "returns error for map update without message" do
      update = %{message: nil}
      assert {:error, :no_message} = Telegram.transform_incoming(update)
    end

    test "returns error for unsupported update type" do
      assert {:error, :unsupported_update_type} = Telegram.transform_incoming("invalid")
    end

    test "handles all chat types" do
      base_message = %Telegex.Type.Message{
        message_id: 1,
        date: 0,
        chat: %Telegex.Type.Chat{id: 1, type: "private"},
        text: "test"
      }

      for {type_str, type_atom} <- [
            {"private", :private},
            {"group", :group},
            {"supergroup", :supergroup},
            {"channel", :channel}
          ] do
        update = %Telegex.Type.Update{
          update_id: 1,
          message: %{base_message | chat: %Telegex.Type.Chat{id: 1, type: type_str}}
        }

        {:ok, incoming} = Telegram.transform_incoming(update)
        assert incoming.chat_type == type_atom
      end
    end
  end
end
