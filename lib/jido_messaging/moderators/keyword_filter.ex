defmodule JidoMessaging.Moderators.KeywordFilter do
  @moduledoc """
  A simple keyword-based content filter.

  Checks message text content against a list of blocked keywords.

  ## Options

  - `:blocked_words` - List of words to block (required)
  - `:action` - `:reject` or `:flag` (default: `:reject`)
  - `:case_sensitive` - Whether matching is case-sensitive (default: false)

  ## Example

      KeywordFilter.moderate(message, blocked_words: ["spam", "scam"], action: :reject)
  """

  @behaviour JidoMessaging.Moderation

  alias JidoMessaging.Content.Text

  @impl true
  def moderate(message, opts) do
    blocked_words = Keyword.get(opts, :blocked_words, [])
    action = Keyword.get(opts, :action, :reject)
    case_sensitive = Keyword.get(opts, :case_sensitive, false)

    text_content = extract_text(message.content)

    case find_blocked_word(text_content, blocked_words, case_sensitive) do
      nil ->
        :allow

      word ->
        description = "Message contains blocked word: #{word}"

        case action do
          :reject -> {:reject, :blocked_word, description}
          :flag -> {:flag, :blocked_word, description}
        end
    end
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map(&extract_text_from_block/1)
    |> Enum.join(" ")
  end

  defp extract_text(_), do: ""

  defp extract_text_from_block(%Text{text: text}), do: text
  defp extract_text_from_block(%{type: :text, text: text}), do: text
  defp extract_text_from_block(%{"type" => "text", "text" => text}), do: text
  defp extract_text_from_block(_), do: ""

  defp find_blocked_word(text, blocked_words, case_sensitive) do
    compare_text = if case_sensitive, do: text, else: String.downcase(text)

    Enum.find(blocked_words, fn word ->
      compare_word = if case_sensitive, do: word, else: String.downcase(word)
      String.contains?(compare_text, compare_word)
    end)
  end
end
