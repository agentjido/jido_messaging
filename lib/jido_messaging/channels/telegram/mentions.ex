defmodule JidoMessaging.Channels.Telegram.Mentions do
  @moduledoc false

  @behaviour JidoMessaging.Adapters.Mentions

  alias JidoMessaging.Adapters.Mentions
  @plain_mention_token ~r/(?<!<)@([A-Za-z0-9._-]+)/

  @impl true
  def parse_mentions(body, raw) when is_binary(body) and is_map(raw) do
    from_entities =
      raw
      |> entities()
      |> Enum.flat_map(&entity_to_mentions(&1, body))

    from_text =
      @plain_mention_token
      |> Regex.scan(body, return: :index)
      |> Enum.flat_map(fn
        [{offset, length}, {capture_offset, capture_length}] ->
          username = binary_part(body, capture_offset, capture_length)
          [%{user_id: username, username: username, offset: offset, length: length}]

        _ ->
          []
      end)
      |> Enum.reject(fn mention ->
        Enum.any?(from_entities, fn entity_mention ->
          entity_mention.offset == mention.offset and entity_mention.length == mention.length
        end)
      end)

    (from_entities ++ from_text)
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

  defp entities(raw) do
    (Map.get(raw, :entities) || Map.get(raw, "entities") || [])
    |> List.wrap()
  end

  defp entity_to_mentions(entity, body) when is_map(entity) do
    case map_get(entity, :type) do
      "text_mention" ->
        [text_mention(entity)]

      "mention" ->
        [inline_mention(entity, body)]

      _ ->
        []
    end
    |> Enum.reject(&is_nil/1)
  end

  defp entity_to_mentions(_, _), do: []

  defp text_mention(entity) do
    user = map_get(entity, :user) || %{}

    %{
      user_id: map_get(user, :id) || map_get(user, :username),
      username: map_get(user, :username),
      offset: to_non_neg_integer(map_get(entity, :offset), 0),
      length: to_non_neg_integer(map_get(entity, :length), 0)
    }
  end

  defp inline_mention(entity, body) do
    offset = to_non_neg_integer(map_get(entity, :offset), 0)
    length = to_non_neg_integer(map_get(entity, :length), 0)

    mention_text =
      case safe_slice(body, offset, length) do
        "@" <> username -> username
        _ -> nil
      end

    %{
      user_id: mention_text,
      username: mention_text,
      offset: offset,
      length: length
    }
  end

  defp safe_slice(body, offset, length)
       when is_binary(body) and is_integer(offset) and is_integer(length) and offset >= 0 and length > 0 do
    body_size = byte_size(body)

    if offset + length <= body_size do
      binary_part(body, offset, length)
    else
      nil
    end
  end

  defp safe_slice(_, _, _), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp to_non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp to_non_neg_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp to_non_neg_integer(_, default), do: default

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_string(value), do: value |> to_string() |> normalize_string()
end
