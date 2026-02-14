defmodule JidoMessaging.Channels.MentionsNormalizationTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channels.{Discord, Slack, Telegram, WhatsApp}

  describe "telegram mentions adapter" do
    test "normalizes entity mentions into canonical maps" do
      body = "@bot /deploy now"

      raw = %{
        "entities" => [
          %{
            "type" => "text_mention",
            "offset" => 0,
            "length" => 4,
            "user" => %{"id" => "BOT_1", "username" => "bot"}
          }
        ]
      }

      mentions = Telegram.Mentions.parse_mentions(body, raw)

      assert mentions == [%{user_id: "BOT_1", username: "bot", offset: 0, length: 4}]
      assert Telegram.Mentions.was_mentioned?(raw, "BOT_1")
    end
  end

  describe "discord mentions adapter" do
    test "normalizes mention list and token offsets" do
      body = "<@BOT_1> /deploy now"

      raw = %{
        mentions: [%{id: "BOT_1", username: "bot"}]
      }

      mentions = Discord.Mentions.parse_mentions(body, raw)

      assert mentions == [%{user_id: "BOT_1", username: "bot", offset: 0, length: 8}]
      assert Discord.Mentions.was_mentioned?(raw, "BOT_1")
    end
  end

  describe "slack mentions adapter" do
    test "normalizes slack mention tokens" do
      body = "<@BOT1> /deploy now"
      raw = %{"text" => body}

      mentions = Slack.Mentions.parse_mentions(body, raw)

      assert mentions == [%{user_id: "BOT1", username: nil, offset: 0, length: 7}]
      assert Slack.Mentions.was_mentioned?(raw, "BOT1")
    end
  end

  describe "whatsapp mentions adapter" do
    test "normalizes @token mentions" do
      body = "@bot1 /deploy now"
      raw = %{"text" => body}

      mentions = WhatsApp.Mentions.parse_mentions(body, raw)

      assert mentions == [%{user_id: "bot1", username: "bot1", offset: 0, length: 5}]
      assert WhatsApp.Mentions.was_mentioned?(raw, "bot1")
    end
  end
end
