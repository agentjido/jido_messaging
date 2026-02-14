defmodule JidoMessaging.Channels.SlackTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channels.Slack

  describe "channel_type/0" do
    test "returns :slack" do
      assert Slack.channel_type() == :slack
    end
  end

  describe "transform_incoming/1 with wrapped events (atom keys)" do
    test "transforms wrapped message event" do
      payload = %{
        event: %{
          type: "message",
          channel: "C1234567890",
          user: "U9876543210",
          text: "Hello bot!",
          ts: "1706745600.123456",
          channel_type: "channel"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "C1234567890"
      assert incoming.external_user_id == "U9876543210"
      assert incoming.text == "Hello bot!"
      assert incoming.external_message_id == "1706745600.123456"
      assert incoming.timestamp == "1706745600.123456"
      assert incoming.chat_type == :channel
      assert incoming.username == nil
      assert incoming.display_name == nil
      assert incoming.chat_title == nil
    end

    test "handles message without optional fields" do
      payload = %{
        event: %{
          type: "message",
          channel: "C1234567890",
          ts: "1706745600.123456"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "C1234567890"
      assert incoming.external_user_id == nil
      assert incoming.text == nil
      assert incoming.chat_type == :unknown
    end
  end

  describe "transform_incoming/1 with wrapped events (string keys)" do
    test "transforms wrapped message event with string keys" do
      payload = %{
        "event" => %{
          "type" => "message",
          "channel" => "C1234567890",
          "user" => "U9876543210",
          "text" => "Hello from string keys!",
          "ts" => "1706745600.789012",
          "channel_type" => "im"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "C1234567890"
      assert incoming.external_user_id == "U9876543210"
      assert incoming.text == "Hello from string keys!"
      assert incoming.external_message_id == "1706745600.789012"
      assert incoming.timestamp == "1706745600.789012"
      assert incoming.chat_type == :dm
    end

    test "handles message without optional fields (string keys)" do
      payload = %{
        "event" => %{
          "type" => "message",
          "channel" => "G0987654321",
          "ts" => "1706745600.999999"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "G0987654321"
      assert incoming.external_user_id == nil
      assert incoming.text == nil
      assert incoming.chat_type == :unknown
    end
  end

  describe "transform_incoming/1 with direct events (atom keys)" do
    test "transforms direct message event" do
      payload = %{
        type: "message",
        channel: "D1234567890",
        user: "U1111111111",
        text: "Direct message",
        ts: "1706745600.111111",
        channel_type: :im
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "D1234567890"
      assert incoming.external_user_id == "U1111111111"
      assert incoming.text == "Direct message"
      assert incoming.chat_type == :dm
    end

    test "handles minimal direct event" do
      payload = %{
        type: "message",
        channel: "C0000000000",
        ts: "1706745600.000000"
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "C0000000000"
      assert incoming.external_message_id == "1706745600.000000"
    end
  end

  describe "transform_incoming/1 with direct events (string keys)" do
    test "transforms direct message event with string keys" do
      payload = %{
        "type" => "message",
        "channel" => "G2222222222",
        "user" => "U3333333333",
        "text" => "Group message",
        "ts" => "1706745600.222222",
        "channel_type" => "group"
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.external_room_id == "G2222222222"
      assert incoming.external_user_id == "U3333333333"
      assert incoming.text == "Group message"
      assert incoming.chat_type == :group
    end
  end

  describe "transform_incoming/1 channel types" do
    test "handles channel type (string)" do
      payload = %{event: %{type: "message", channel: "C123", ts: "1", channel_type: "channel"}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :channel
    end

    test "handles group type (string)" do
      payload = %{event: %{type: "message", channel: "G123", ts: "1", channel_type: "group"}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :group
    end

    test "handles im type (string)" do
      payload = %{event: %{type: "message", channel: "D123", ts: "1", channel_type: "im"}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :dm
    end

    test "handles mpim type (string)" do
      payload = %{event: %{type: "message", channel: "G123", ts: "1", channel_type: "mpim"}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :group_dm
    end

    test "handles channel type (atom)" do
      payload = %{type: "message", channel: "C123", ts: "1", channel_type: :channel}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :channel
    end

    test "handles group type (atom)" do
      payload = %{type: "message", channel: "G123", ts: "1", channel_type: :group}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :group
    end

    test "handles im type (atom)" do
      payload = %{type: "message", channel: "D123", ts: "1", channel_type: :im}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :dm
    end

    test "handles mpim type (atom)" do
      payload = %{type: "message", channel: "G123", ts: "1", channel_type: :mpim}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :group_dm
    end

    test "handles nil channel type" do
      payload = %{event: %{type: "message", channel: "C123", ts: "1", channel_type: nil}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :unknown
    end

    test "handles missing channel type" do
      payload = %{event: %{type: "message", channel: "C123", ts: "1"}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :unknown
    end

    test "handles unknown channel type string" do
      payload = %{event: %{type: "message", channel: "X123", ts: "1", channel_type: "unknown_type"}}
      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.chat_type == :unknown
    end
  end

  describe "transform_incoming/1 error cases" do
    test "returns error for unsupported event type" do
      payload = %{event: %{type: "app_mention", channel: "C123", ts: "1"}}
      assert {:error, :unsupported_event_type} = Slack.transform_incoming(payload)
    end

    test "returns error for reaction event" do
      payload = %{event: %{type: "reaction_added", channel: "C123", ts: "1"}}
      assert {:error, :unsupported_event_type} = Slack.transform_incoming(payload)
    end

    test "returns error for nil payload" do
      assert {:error, :unsupported_event_type} = Slack.transform_incoming(nil)
    end

    test "returns error for empty map" do
      assert {:error, :unsupported_event_type} = Slack.transform_incoming(%{})
    end

    test "returns error for invalid payload structure" do
      assert {:error, :unsupported_event_type} = Slack.transform_incoming("invalid")
    end

    test "returns error for wrapped event with wrong type" do
      payload = %{"event" => %{"type" => "file_shared", "channel" => "C123"}}
      assert {:error, :unsupported_event_type} = Slack.transform_incoming(payload)
    end

    test "returns error for list payload" do
      assert {:error, :unsupported_event_type} = Slack.transform_incoming([])
    end

    test "returns error for integer payload" do
      assert {:error, :unsupported_event_type} = Slack.transform_incoming(123)
    end
  end

  describe "transform_incoming/1 comprehensive payload variations" do
    test "handles thread replies" do
      payload = %{
        event: %{
          type: "message",
          channel: "C1234567890",
          user: "U9876543210",
          text: "Thread reply",
          ts: "1706745601.123456",
          thread_ts: "1706745600.123456",
          channel_type: "channel"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.text == "Thread reply"
      assert incoming.external_message_id == "1706745601.123456"
    end

    test "handles bot messages" do
      payload = %{
        event: %{
          type: "message",
          channel: "C1234567890",
          bot_id: "B1234567890",
          text: "Bot message",
          ts: "1706745600.123456",
          channel_type: "channel"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.text == "Bot message"
      assert incoming.external_user_id == nil
    end

    test "handles message with blocks" do
      payload = %{
        "event" => %{
          "type" => "message",
          "channel" => "C1234567890",
          "user" => "U9876543210",
          "text" => "Message with blocks",
          "ts" => "1706745600.123456",
          "blocks" => [
            %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => "Block text"}}
          ],
          "channel_type" => "channel"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert incoming.text == "Message with blocks"
    end

    test "extracts files into normalized media payloads" do
      payload = %{
        "event" => %{
          "type" => "message",
          "channel" => "C1234567890",
          "user" => "U9876543210",
          "text" => "Message with file",
          "ts" => "1706745600.333333",
          "files" => [
            %{
              "id" => "F12345",
              "mimetype" => "image/png",
              "url_private" => "https://files.slack.com/image.png",
              "name" => "image.png",
              "size" => 2048
            }
          ],
          "channel_type" => "channel"
        }
      }

      assert {:ok, incoming} = Slack.transform_incoming(payload)
      assert [%{kind: :image, url: "https://files.slack.com/image.png", media_type: "image/png"}] = incoming.media
    end
  end
end
