defmodule JidoMessaging.Channels.WhatsApp.Mentions do
  @moduledoc false

  @behaviour JidoMessaging.Adapters.Mentions

  alias JidoMessaging.Adapters.Mentions

  @mention_token ~r/@([A-Za-z0-9._-]+)/

  @impl true
  def parse_mentions(body, raw) when is_binary(body) and is_map(raw) do
    from_context = context_mentions(raw, body)

    from_text =
      @mention_token
      |> Regex.scan(body, return: :index)
      |> Enum.flat_map(fn
        [{offset, length}, {capture_offset, capture_length}] ->
          mention_id = binary_part(body, capture_offset, capture_length)
          [%{user_id: mention_id, username: mention_id, offset: offset, length: length}]

        _ ->
          []
      end)

    (from_context ++ from_text)
    |> Mentions.normalize_mentions()
  end

  @impl true
  def was_mentioned?(raw, bot_id) when is_map(raw) and is_binary(bot_id) do
    normalized_bot_id = normalize_string(bot_id)
    text = Map.get(raw, :text) || Map.get(raw, "text") || ""

    parse_mentions(text, raw)
    |> Enum.any?(fn mention ->
      mention
      |> Map.get(:user_id)
      |> normalize_string()
      |> Kernel.==(normalized_bot_id)
    end)
  end

  defp context_mentions(raw, body) do
    (Map.get(raw, :context) || Map.get(raw, "context") || %{})
    |> case do
      context when is_map(context) ->
        Map.get(context, :mentioned_users) || Map.get(context, "mentioned_users") || []

      _ ->
        []
    end
    |> Enum.flat_map(fn user_id ->
      mention_offsets(body, user_id)
      |> Enum.map(fn {offset, length} ->
        %{
          user_id: user_id,
          username: user_id,
          offset: offset,
          length: length
        }
      end)
    end)
  end

  defp mention_offsets(body, user_id) do
    regex = Regex.compile!("@#{Regex.escape(to_string(user_id))}")

    regex
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn
      [{offset, length}] -> [{offset, length}]
      _ -> []
    end)
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()
end
