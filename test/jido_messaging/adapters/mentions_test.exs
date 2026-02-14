defmodule JidoMessaging.Adapters.MentionsTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Adapters.Mentions

  defmodule FullMentionsAdapter do
    @behaviour JidoMessaging.Adapters.Mentions

    @impl true
    def parse_mentions(_body, raw) do
      entities = raw["entities"] || []

      entities
      |> Enum.filter(&(&1["type"] == "mention"))
      |> Enum.map(fn entity ->
        %{
          user_id: to_string(entity["user_id"]),
          username: entity["username"],
          offset: entity["offset"],
          length: entity["length"]
        }
      end)
    end

    @impl true
    def strip_mentions(body, mentions) do
      Mentions.default_strip_mentions(body, mentions)
    end

    @impl true
    def was_mentioned?(raw, bot_id) do
      entities = raw["entities"] || []

      Enum.any?(entities, fn e ->
        e["type"] == "mention" and to_string(e["user_id"]) == bot_id
      end)
    end
  end

  defmodule PartialMentionsAdapter do
    @behaviour JidoMessaging.Adapters.Mentions

    @impl true
    def parse_mentions(_body, _raw), do: []

    @impl true
    def was_mentioned?(_raw, _bot_id), do: false
  end

  defmodule NoMentionsAdapter do
    def some_other_function, do: :ok
  end

  describe "parse_mentions/3" do
    test "parses mentions from raw payload" do
      raw = %{
        "entities" => [
          %{
            "type" => "mention",
            "user_id" => 123,
            "username" => "john",
            "offset" => 0,
            "length" => 5
          },
          %{
            "type" => "mention",
            "user_id" => 456,
            "username" => "jane",
            "offset" => 6,
            "length" => 5
          }
        ]
      }

      mentions = Mentions.parse_mentions(FullMentionsAdapter, "@john @jane hello", raw)

      assert length(mentions) == 2
      assert Enum.at(mentions, 0).user_id == "123"
      assert Enum.at(mentions, 0).username == "john"
      assert Enum.at(mentions, 1).user_id == "456"
    end

    test "returns empty list for module without callback" do
      mentions = Mentions.parse_mentions(NoMentionsAdapter, "hello", %{})
      assert mentions == []
    end

    test "returns empty list for adapter returning empty" do
      mentions = Mentions.parse_mentions(PartialMentionsAdapter, "hello", %{})
      assert mentions == []
    end
  end

  describe "strip_mentions/3" do
    test "strips mentions from body using adapter" do
      mentions = [
        %{user_id: "123", username: "john", offset: 0, length: 5}
      ]

      result = Mentions.strip_mentions(FullMentionsAdapter, "@john hello", mentions)
      assert result == " hello"
    end

    test "returns original body for module without callback" do
      mentions = [%{user_id: "123", username: "john", offset: 0, length: 5}]
      result = Mentions.strip_mentions(NoMentionsAdapter, "@john hello", mentions)
      assert result == "@john hello"
    end

    test "returns original body for partial adapter" do
      mentions = [%{user_id: "123", username: "john", offset: 0, length: 5}]
      result = Mentions.strip_mentions(PartialMentionsAdapter, "@john hello", mentions)
      assert result == "@john hello"
    end
  end

  describe "was_mentioned?/3" do
    test "returns true when bot was mentioned" do
      raw = %{
        "entities" => [
          %{"type" => "mention", "user_id" => 123}
        ]
      }

      assert Mentions.was_mentioned?(FullMentionsAdapter, raw, "123")
    end

    test "returns false when bot was not mentioned" do
      raw = %{
        "entities" => [
          %{"type" => "mention", "user_id" => 456}
        ]
      }

      refute Mentions.was_mentioned?(FullMentionsAdapter, raw, "123")
    end

    test "returns false for module without callback" do
      refute Mentions.was_mentioned?(NoMentionsAdapter, %{}, "123")
    end
  end

  describe "implements?/1" do
    test "returns true for modules implementing Mentions behaviour" do
      assert Mentions.implements?(FullMentionsAdapter)
      assert Mentions.implements?(PartialMentionsAdapter)
    end

    test "returns false for modules not implementing Mentions behaviour" do
      refute Mentions.implements?(NoMentionsAdapter)
      refute Mentions.implements?(String)
    end
  end

  describe "default_strip_mentions/2" do
    test "strips single mention" do
      mentions = [%{offset: 0, length: 5, user_id: "1", username: nil}]
      result = Mentions.default_strip_mentions("@john hello", mentions)
      assert result == " hello"
    end

    test "strips multiple mentions" do
      mentions = [
        %{offset: 0, length: 5, user_id: "1", username: nil},
        %{offset: 6, length: 5, user_id: "2", username: nil}
      ]

      result = Mentions.default_strip_mentions("@john @jane hello", mentions)
      assert result == "  hello"
    end

    test "handles mentions at end of string" do
      mentions = [%{offset: 6, length: 5, user_id: "1", username: nil}]
      result = Mentions.default_strip_mentions("hello @john", mentions)
      assert result == "hello "
    end

    test "handles empty mentions list" do
      result = Mentions.default_strip_mentions("hello", [])
      assert result == "hello"
    end

    test "handles overlapping mention removal correctly" do
      mentions = [
        %{offset: 0, length: 3, user_id: "1", username: nil},
        %{offset: 4, length: 3, user_id: "2", username: nil},
        %{offset: 8, length: 3, user_id: "3", username: nil}
      ]

      result = Mentions.default_strip_mentions("@ab @cd @ef hi", mentions)
      assert result == "   hi"
    end
  end

  describe "normalize_mentions/1" do
    test "normalizes key formats and de-duplicates deterministically" do
      mentions = [
        %{"user_id" => 123, "username" => "john", "offset" => "0", "length" => "5"},
        %{user_id: "123", username: "john", offset: 0, length: 5},
        %{user_id: "456", username: "jane", offset: 6, length: 4}
      ]

      assert Mentions.normalize_mentions(mentions) == [
               %{user_id: "123", username: "john", offset: 0, length: 5},
               %{user_id: "456", username: "jane", offset: 6, length: 4}
             ]
    end

    test "drops invalid mention entries" do
      mentions = [
        %{offset: 0, length: 5},
        %{user_id: "123", offset: 0, length: 0},
        :invalid
      ]

      assert Mentions.normalize_mentions(mentions) == []
    end
  end
end
