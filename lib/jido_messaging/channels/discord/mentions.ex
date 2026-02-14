defmodule JidoMessaging.Channels.Discord.Mentions do
  @moduledoc false

  @behaviour JidoMessaging.Adapters.Mentions

  alias JidoMessaging.Adapters.Mentions

  @mention_token ~r/<@!?([A-Za-z0-9_]+)>/
  @plain_mention_token ~r/(?<!<)@([A-Za-z0-9._-]+)/

  @impl true
  def parse_mentions(body, raw) when is_binary(body) and is_map(raw) do
    from_mentions_list =
      raw
      |> mentions_list()
      |> Enum.flat_map(&mention_from_raw(&1, body))

    from_tokens = mention_tokens(body)
    from_plain_tokens = plain_mention_tokens(body)

    (from_mentions_list ++ from_tokens ++ from_plain_tokens)
    |> Mentions.normalize_mentions()
  end

  @impl true
  def was_mentioned?(raw, bot_id) when is_map(raw) and is_binary(bot_id) do
    normalized_bot_id = normalize_string(bot_id)
    text = Map.get(raw, :content) || Map.get(raw, "content") || ""

    mention_list_hit? =
      raw
      |> mentions_list()
      |> Enum.any?(fn mention ->
        mention
        |> map_get(:id)
        |> normalize_string()
        |> Kernel.==(normalized_bot_id)
      end)

    mention_list_hit? or
      Enum.any?(parse_mentions(text, raw), fn mention ->
        mention
        |> Map.get(:user_id)
        |> normalize_string()
        |> Kernel.==(normalized_bot_id)
      end)
  end

  defp mentions_list(raw) do
    (Map.get(raw, :mentions) || Map.get(raw, "mentions") || [])
    |> List.wrap()
  end

  defp mention_from_raw(mention, body) when is_map(mention) and is_binary(body) do
    user_id = mention |> map_get(:id) |> normalize_string()
    username = mention |> map_get(:username) |> normalize_string()

    cond do
      is_nil(user_id) ->
        []

      true ->
        mention_token_offsets(body, user_id)
        |> Enum.map(fn {offset, length} ->
          %{user_id: user_id, username: username, offset: offset, length: length}
        end)
    end
  end

  defp mention_from_raw(_, _), do: []

  defp mention_token_offsets(body, user_id) do
    regex = Regex.compile!("<@!?#{Regex.escape(user_id)}>")

    regex
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn
      [{offset, length}] -> [{offset, length}]
      _ -> []
    end)
  end

  defp mention_tokens(body) do
    @mention_token
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn
      [{offset, length}, {capture_offset, capture_length}] ->
        user_id = binary_part(body, capture_offset, capture_length)
        [%{user_id: user_id, username: nil, offset: offset, length: length}]

      _ ->
        []
    end)
  end

  defp plain_mention_tokens(body) do
    @plain_mention_token
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn
      [{offset, length}, {capture_offset, capture_length}] ->
        user_id = binary_part(body, capture_offset, capture_length)
        [%{user_id: user_id, username: user_id, offset: offset, length: length}]

      _ ->
        []
    end)
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()
end
