defmodule JidoMessaging.Channels.Slack.Mentions do
  @moduledoc false

  @behaviour JidoMessaging.Adapters.Mentions

  alias JidoMessaging.Adapters.Mentions

  @mention_token ~r/<@([A-Za-z0-9]+)(?:\|[^>]+)?>/
  @plain_mention_token ~r/(?<!<)@([A-Za-z0-9._-]+)/

  @impl true
  def parse_mentions(body, _raw) when is_binary(body) do
    from_slack_tokens =
      @mention_token
      |> Regex.scan(body, return: :index)
      |> Enum.flat_map(fn
        [{offset, length}, {capture_offset, capture_length}] ->
          user_id = binary_part(body, capture_offset, capture_length)
          [%{user_id: user_id, username: nil, offset: offset, length: length}]

        _ ->
          []
      end)

    from_plain_tokens =
      @plain_mention_token
      |> Regex.scan(body, return: :index)
      |> Enum.flat_map(fn
        [{offset, length}, {capture_offset, capture_length}] ->
          user_id = binary_part(body, capture_offset, capture_length)
          [%{user_id: user_id, username: user_id, offset: offset, length: length}]

        _ ->
          []
      end)

    (from_slack_tokens ++ from_plain_tokens)
    |> Mentions.normalize_mentions()
  end

  @impl true
  def was_mentioned?(raw, bot_id) when is_map(raw) and is_binary(bot_id) do
    text = Map.get(raw, :text) || Map.get(raw, "text") || ""
    normalized_bot_id = normalize_string(bot_id)

    parse_mentions(text, raw)
    |> Enum.any?(fn mention ->
      mention
      |> Map.get(:user_id)
      |> normalize_string()
      |> Kernel.==(normalized_bot_id)
    end)
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()
end
