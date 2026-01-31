defmodule JidoMessaging.ModerationTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Moderation
  alias JidoMessaging.Moderators.{KeywordFilter, RateLimiter}
  alias JidoMessaging.Message
  alias JidoMessaging.Content.Text

  defmodule AllowAllModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(_message, _opts), do: :allow
  end

  defmodule FlagModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(_message, _opts), do: {:flag, :test_flag, "Test flag"}
  end

  defmodule RejectModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(_message, _opts), do: {:reject, :test_reject, "Test rejection"}
  end

  defmodule ModifyModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(message, _opts) do
      modified = %{message | metadata: Map.put(message.metadata, :modified, true)}
      {:modify, modified}
    end
  end

  describe "Moderation.apply_moderators/3" do
    test "allows message when all moderators allow" do
      message = build_message("Hello world")

      result = Moderation.apply_moderators(message, [AllowAllModerator, AllowAllModerator])

      assert {:ok, ^message, []} = result
    end

    test "rejects message when any moderator rejects" do
      message = build_message("Hello world")

      result = Moderation.apply_moderators(message, [AllowAllModerator, RejectModerator, AllowAllModerator])

      assert {:error, :test_reject, "Test rejection"} = result
    end

    test "accumulates flags from multiple moderators" do
      message = build_message("Hello world")

      result = Moderation.apply_moderators(message, [FlagModerator, AllowAllModerator, FlagModerator])

      assert {:ok, ^message, flags} = result
      assert length(flags) == 2
      assert {:test_flag, "Test flag"} in flags
    end

    test "applies modifications in order" do
      message = build_message("Hello world")

      {:ok, modified, []} = Moderation.apply_moderators(message, [ModifyModerator])

      assert modified.metadata[:modified] == true
    end

    test "empty moderators list allows message" do
      message = build_message("Hello world")

      result = Moderation.apply_moderators(message, [])

      assert {:ok, ^message, []} = result
    end
  end

  describe "Moderation.allowed?/1" do
    test "returns true for :allow" do
      assert Moderation.allowed?(:allow) == true
    end

    test "returns true for :flag" do
      assert Moderation.allowed?({:flag, :reason, "desc"}) == true
    end

    test "returns true for :modify" do
      assert Moderation.allowed?({:modify, %{}}) == true
    end

    test "returns false for :reject" do
      assert Moderation.allowed?({:reject, :reason, "desc"}) == false
    end
  end

  describe "KeywordFilter" do
    test "allows message without blocked words" do
      message = build_message("Hello world")

      result = KeywordFilter.moderate(message, blocked_words: ["spam", "scam"])

      assert result == :allow
    end

    test "rejects message with blocked word" do
      message = build_message("This is spam content")

      result = KeywordFilter.moderate(message, blocked_words: ["spam", "scam"])

      assert {:reject, :blocked_word, description} = result
      assert description =~ "spam"
    end

    test "flags message when action is :flag" do
      message = build_message("This is spam content")

      result = KeywordFilter.moderate(message, blocked_words: ["spam"], action: :flag)

      assert {:flag, :blocked_word, description} = result
      assert description =~ "spam"
    end

    test "case insensitive matching by default" do
      message = build_message("This is SPAM content")

      result = KeywordFilter.moderate(message, blocked_words: ["spam"])

      assert {:reject, :blocked_word, _} = result
    end

    test "case sensitive matching when enabled" do
      message = build_message("This is SPAM content")

      result = KeywordFilter.moderate(message, blocked_words: ["spam"], case_sensitive: true)

      assert result == :allow
    end

    test "handles Text struct content" do
      message = build_message_with_struct("This is spam content")

      result = KeywordFilter.moderate(message, blocked_words: ["spam"])

      assert {:reject, :blocked_word, _} = result
    end

    test "handles empty content" do
      message = %Message{
        id: "msg_1",
        room_id: "room_1",
        sender_id: "user_1",
        role: :user,
        content: []
      }

      result = KeywordFilter.moderate(message, blocked_words: ["spam"])

      assert result == :allow
    end

    test "handles string key map content" do
      message =
        Message.new(%{
          room_id: "room_1",
          sender_id: "user_1",
          role: :user,
          content: [%{"type" => "text", "text" => "This is spam"}]
        })

      result = KeywordFilter.moderate(message, blocked_words: ["spam"])

      assert {:reject, :blocked_word, _} = result
    end

    test "handles non-text content blocks" do
      message =
        Message.new(%{
          room_id: "room_1",
          sender_id: "user_1",
          role: :user,
          content: [%{type: :image, url: "https://example.com/spam.jpg"}]
        })

      result = KeywordFilter.moderate(message, blocked_words: ["spam"])

      assert result == :allow
    end
  end

  describe "RateLimiter" do
    test "allows messages under the limit" do
      table = :"rate_limit_test_#{:erlang.unique_integer([:positive])}"
      message = build_message("Hello")

      result = RateLimiter.moderate(message, table: table, max_messages: 5)

      assert result == :allow
    end

    test "rejects messages over the limit" do
      table = :"rate_limit_test_#{:erlang.unique_integer([:positive])}"
      message = build_message("Hello")

      for _ <- 1..5 do
        assert :allow = RateLimiter.moderate(message, table: table, max_messages: 5)
      end

      result = RateLimiter.moderate(message, table: table, max_messages: 5)

      assert {:reject, :rate_limited, description} = result
      assert description =~ "Rate limit exceeded"
    end

    test "different senders have separate limits" do
      table = :"rate_limit_test_#{:erlang.unique_integer([:positive])}"
      message1 = %{build_message("Hello") | sender_id: "user_1"}
      message2 = %{build_message("Hello") | sender_id: "user_2"}

      for _ <- 1..5 do
        RateLimiter.moderate(message1, table: table, max_messages: 5)
      end

      result = RateLimiter.moderate(message2, table: table, max_messages: 5)

      assert result == :allow
    end

    test "reset clears rate limit for sender" do
      table = :"rate_limit_test_#{:erlang.unique_integer([:positive])}"
      message = build_message("Hello")

      for _ <- 1..5 do
        RateLimiter.moderate(message, table: table, max_messages: 5)
      end

      RateLimiter.reset(message.sender_id, table)

      result = RateLimiter.moderate(message, table: table, max_messages: 5)

      assert result == :allow
    end

    test "get_count returns current message count" do
      table = :"rate_limit_test_#{:erlang.unique_integer([:positive])}"
      message = build_message("Hello")

      for _ <- 1..3 do
        RateLimiter.moderate(message, table: table, max_messages: 10)
      end

      count = RateLimiter.get_count(message.sender_id, table: table)

      assert count == 3
    end

    test "get_count returns 0 for unknown sender" do
      table = :"rate_limit_test_#{:erlang.unique_integer([:positive])}"
      RateLimiter.init(table)
      count = RateLimiter.get_count("unknown_sender", table: table)

      assert count == 0
    end
  end

  defp build_message(text) do
    Message.new(%{
      room_id: "room_1",
      sender_id: "user_1",
      role: :user,
      content: [%{type: :text, text: text}]
    })
  end

  defp build_message_with_struct(text) do
    Message.new(%{
      room_id: "room_1",
      sender_id: "user_1",
      role: :user,
      content: [Text.new(text)]
    })
  end
end
