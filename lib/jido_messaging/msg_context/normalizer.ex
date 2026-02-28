defmodule Jido.Messaging.MsgContext.Normalizer do
  @moduledoc """
  Command and mention normalization for `MsgContext`.
  """

  alias Jido.Chat.Mention
  alias Jido.Messaging.MsgContext
  alias Jido.Messaging.MsgContext.CommandParser
  alias Jido.Messaging.BridgeRegistry

  @default_mentions_max_text_bytes 2048

  @type opts :: keyword()

  @doc """
  Enriches an existing `MsgContext` with normalized mention and command metadata.

  ## Options

    * `:mention_targets` - IDs/usernames used to compute `was_mentioned`
    * `:command_prefixes` - parser prefix candidates
    * `:command_max_text_bytes` - parser max text size
    * `:mentions_max_text_bytes` - max text size for adapter mention parsing
  """
  @spec normalize(MsgContext.t(), map(), opts()) :: MsgContext.t()
  def normalize(%MsgContext{} = msg_context, incoming, opts \\ []) when is_map(incoming) and is_list(opts) do
    body = normalize_body(msg_context.body)
    raw = normalize_raw_payload(incoming, msg_context)
    mentions_adapter = resolve_mentions_adapter(msg_context)

    mentions =
      parse_mentions(msg_context, mentions_adapter, body, raw, opts)
      |> normalize_mentions()

    mention_targets = mention_targets(msg_context, opts)

    was_mentioned =
      normalize_was_mentioned(
        msg_context,
        mentions,
        mention_targets,
        mentions_adapter,
        raw,
        body
      )

    command = normalize_command(body, mentions, opts)

    emit_command_telemetry(msg_context.channel_type, command)
    emit_mentions_telemetry(msg_context.channel_type, mentions_adapter, mentions, was_mentioned)

    %{
      msg_context
      | body: body,
        raw: raw,
        mentions: mentions,
        was_mentioned: was_mentioned,
        command: command
    }
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(_), do: ""

  defp normalize_raw_payload(incoming, msg_context) do
    raw = Map.get(incoming, :raw) || msg_context.raw
    if is_map(raw), do: raw, else: %{}
  end

  defp parse_mentions(msg_context, mentions_adapter, body, raw, opts) do
    base_mentions = normalize_mentions(msg_context.mentions || [])

    adapter_mentions =
      cond do
        is_nil(mentions_adapter) ->
          []

        body == "" ->
          []

        byte_size(body) > mentions_max_text_bytes(opts) ->
          []

        true ->
          parse_mentions_with_adapter(mentions_adapter, body, raw)
      end

    base_mentions ++ adapter_mentions
  end

  defp normalize_was_mentioned(msg_context, mentions, mention_targets, mentions_adapter, raw, body) do
    explicit_mention = msg_context.was_mentioned == true

    from_targets =
      cond do
        mention_targets == [] ->
          mentions != []

        true ->
          mentions_match_target?(mentions, mention_targets) or
            adapter_mentions_target?(mentions_adapter, raw, mention_targets) or
            body_mentions_target?(body, mention_targets)
      end

    explicit_mention or from_targets
  end

  defp normalize_command(body, mentions, opts) do
    parser_opts =
      [
        prefixes: CommandParser.normalize_prefixes(Keyword.get(opts, :command_prefixes)),
        max_text_bytes: command_max_text_bytes(opts)
      ]

    body_parse = CommandParser.parse(body, parser_opts)

    case strip_leading_mention(body, mentions) do
      ^body ->
        body_parse

      stripped_body ->
        stripped_parse = CommandParser.parse(stripped_body, parser_opts) |> CommandParser.with_source(:mention_stripped)

        choose_command_parse(body_parse, stripped_parse)
    end
  end

  defp choose_command_parse(%{status: :ok} = primary, _fallback), do: primary
  defp choose_command_parse(_primary, %{status: :ok} = fallback), do: fallback

  defp choose_command_parse(%{status: :error} = primary, %{status: :none} = _fallback),
    do: primary

  defp choose_command_parse(%{status: :none} = _primary, %{status: :error} = fallback),
    do: fallback

  defp choose_command_parse(primary, _fallback), do: primary

  defp strip_leading_mention(body, mentions) do
    case leading_mention(mentions) do
      nil ->
        body

      mention ->
        offset = mention_offset(mention)
        length = mention_length(mention)
        max_len = byte_size(body)

        if offset == 0 and length > 0 and length <= max_len do
          binary_part(body, length, max_len - length)
          |> String.replace(~r/^[\s,:;\-]+/u, "")
        else
          body
        end
    end
  end

  defp leading_mention(mentions) do
    mentions
    |> Enum.sort_by(fn mention -> {mention_offset(mention), mention_length(mention)} end)
    |> Enum.find(fn mention -> mention_offset(mention) == 0 end)
  end

  defp mention_targets(msg_context, opts) do
    opts
    |> Keyword.get(:mention_targets, [msg_context.bridge_id])
    |> normalize_targets()
  end

  defp normalize_targets(targets) when is_list(targets) do
    targets
    |> Enum.reduce([], fn target, acc ->
      case normalize_target(target) do
        nil -> acc
        normalized -> [normalized | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp normalize_targets(target), do: normalize_targets([target])

  defp mentions_match_target?(mentions, mention_targets) do
    target_set = MapSet.new(mention_targets)

    Enum.any?(mentions, fn mention ->
      mention_id = normalize_target(mention.user_id)
      mention_username = normalize_target(mention.username)

      (not is_nil(mention_id) and MapSet.member?(target_set, mention_id)) or
        (not is_nil(mention_username) and MapSet.member?(target_set, mention_username))
    end)
  end

  defp adapter_mentions_target?(nil, _raw, _mention_targets), do: false

  defp adapter_mentions_target?(mentions_adapter, raw, mention_targets) do
    Enum.any?(mention_targets, fn mention_target ->
      adapter_was_mentioned?(mentions_adapter, raw, mention_target)
    end)
  end

  defp body_mentions_target?(body, mention_targets) when is_binary(body) do
    downcased_body = String.downcase(body)

    Enum.any?(mention_targets, fn mention_target ->
      token = "@" <> mention_target
      String.contains?(downcased_body, token)
    end)
  end

  defp normalize_target(nil), do: nil

  defp normalize_target(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_target(value), do: value |> to_string() |> normalize_target()

  defp resolve_mentions_adapter(%MsgContext{channel_module: channel_module, channel_type: channel_type}) do
    registry_adapter =
      if is_atom(channel_type) do
        BridgeRegistry.get_adapter(channel_type, :mentions)
      else
        nil
      end

    cond do
      valid_mentions_adapter?(registry_adapter) ->
        registry_adapter

      valid_mentions_adapter?(default_mentions_adapter(channel_module)) ->
        default_mentions_adapter(channel_module)

      true ->
        nil
    end
  end

  defp default_mentions_adapter(channel_module) when is_atom(channel_module) do
    Module.concat(channel_module, :Mentions)
  end

  defp default_mentions_adapter(_), do: nil

  defp valid_mentions_adapter?(module) when is_atom(module) do
    function_exported?(module, :parse_mentions, 3) or
      function_exported?(module, :parse_mentions, 2) or
      function_exported?(module, :was_mentioned?, 3) or
      function_exported?(module, :was_mentioned?, 2)
  end

  defp parse_mentions_with_adapter(module, body, raw) when is_atom(module) do
    cond do
      function_exported?(module, :parse_mentions, 3) ->
        module.parse_mentions(module, body, raw)

      function_exported?(module, :parse_mentions, 2) ->
        module.parse_mentions(body, raw)

      true ->
        detect_mentions_from_body(body)
    end
  rescue
    _ -> detect_mentions_from_body(body)
  catch
    _kind, _reason -> detect_mentions_from_body(body)
  end

  defp detect_mentions_from_body(body) when is_binary(body) do
    Regex.scan(~r/@([A-Za-z0-9_]+)/u, body, return: :index)
    |> Enum.map(fn [{offset, length}, {user_offset, user_len}] ->
      username = binary_part(body, user_offset, user_len)
      mention_text = binary_part(body, offset, length)

      Mention.new(%{
        username: username,
        mention_text: mention_text,
        metadata: %{offset: offset, length: length}
      })
    end)
  end

  defp normalize_mentions(mentions) when is_list(mentions) do
    mentions
    |> Enum.flat_map(fn
      %Mention{} = mention ->
        [mention]

      mention when is_map(mention) ->
        [mention_to_struct(mention)]

      _ ->
        []
    end)
  end

  defp normalize_mentions(_), do: []

  defp mention_to_struct(mention) when is_map(mention) do
    user_id = mention[:user_id] || mention["user_id"]
    username = mention[:username] || mention["username"]
    display_name = mention[:display_name] || mention["display_name"]
    mention_text = mention[:mention_text] || mention["mention_text"] || mention[:text] || mention["text"]
    offset = mention[:offset] || mention["offset"]
    length = mention[:length] || mention["length"]
    metadata = (mention[:metadata] || mention["metadata"] || %{}) |> normalize_mention_metadata(offset, length)

    Mention.new(%{
      user_id: user_id,
      username: username,
      display_name: display_name,
      mention_text: mention_text,
      metadata: metadata
    })
  rescue
    _ -> Mention.new(%{metadata: %{}})
  end

  defp normalize_mention_metadata(metadata, offset, length) when is_map(metadata) do
    metadata
    |> maybe_put_offset(offset)
    |> maybe_put_length(length)
  end

  defp normalize_mention_metadata(_metadata, offset, length) do
    %{}
    |> maybe_put_offset(offset)
    |> maybe_put_length(length)
  end

  defp maybe_put_offset(metadata, offset) when is_integer(offset), do: Map.put(metadata, :offset, offset)
  defp maybe_put_offset(metadata, _offset), do: metadata
  defp maybe_put_length(metadata, length) when is_integer(length), do: Map.put(metadata, :length, length)
  defp maybe_put_length(metadata, _length), do: metadata

  defp mention_offset(%Mention{metadata: metadata}) when is_map(metadata) do
    value = metadata[:offset] || metadata["offset"]
    if is_integer(value), do: value, else: 9_999_999
  end

  defp mention_offset(_mention), do: 9_999_999

  defp mention_length(%Mention{metadata: metadata, mention_text: mention_text}) when is_map(metadata) do
    value = metadata[:length] || metadata["length"]

    cond do
      is_integer(value) and value > 0 -> value
      is_binary(mention_text) and mention_text != "" -> byte_size(mention_text)
      true -> 0
    end
  end

  defp mention_length(_mention), do: 0

  defp adapter_was_mentioned?(module, raw, mention_target) when is_atom(module) do
    cond do
      function_exported?(module, :was_mentioned?, 3) ->
        module.was_mentioned?(module, raw, mention_target)

      function_exported?(module, :was_mentioned?, 2) ->
        module.was_mentioned?(raw, mention_target)

      true ->
        false
    end
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp command_max_text_bytes(opts) do
    case Keyword.get(opts, :command_max_text_bytes, @default_mentions_max_text_bytes) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_mentions_max_text_bytes
    end
  end

  defp mentions_max_text_bytes(opts) do
    case Keyword.get(opts, :mentions_max_text_bytes, @default_mentions_max_text_bytes) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_mentions_max_text_bytes
    end
  end

  defp emit_command_telemetry(channel_type, command) do
    :telemetry.execute(
      [:jido_messaging, :ingest, :command, :parsed],
      %{text_bytes: command.text_bytes},
      %{
        channel_type: channel_type,
        status: command.status,
        reason: command.reason,
        prefix: command.prefix,
        source: command.source
      }
    )
  end

  defp emit_mentions_telemetry(channel_type, mentions_adapter, mentions, was_mentioned) do
    :telemetry.execute(
      [:jido_messaging, :ingest, :mentions, :normalized],
      %{count: length(mentions)},
      %{
        channel_type: channel_type,
        adapter: mentions_adapter,
        was_mentioned: was_mentioned
      }
    )
  end
end
