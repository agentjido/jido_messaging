defmodule JidoMessaging.MsgContext.CommandParser do
  @moduledoc """
  Deterministic command parser for normalized inbound message text.

  The parser is intentionally bounded and conservative for hot-path safety.
  """

  @default_max_text_bytes 2048
  @default_prefixes ["/", "!"]

  @type parse_status :: :ok | :none | :error

  @type reason ::
          :empty_text
          | :not_command
          | :text_too_long
          | :missing_command_name
          | :invalid_command_name
          | :invalid_prefixes
          | :invalid_text

  @type command_envelope :: %{
          status: parse_status(),
          source: :body | :mention_stripped,
          prefix: String.t() | nil,
          name: String.t() | nil,
          args: String.t() | nil,
          argv: [String.t()],
          reason: reason() | nil,
          text_bytes: non_neg_integer()
        }

  @doc """
  Parses a command envelope from text.

  ## Options

    * `:prefixes` - accepted command prefixes (default: `#{inspect(@default_prefixes)}`)
    * `:max_text_bytes` - upper bound for parser evaluation (default: `#{@default_max_text_bytes}`)
  """
  @spec parse(String.t() | nil, keyword()) :: command_envelope()
  def parse(text, opts \\ []) when is_list(opts) do
    do_parse(text, opts, :body)
  end

  @doc """
  Returns normalized command prefixes.
  """
  @spec normalize_prefixes(term()) :: [String.t()]
  def normalize_prefixes(prefixes) when is_list(prefixes) do
    prefixes
    |> Enum.reduce([], fn prefix, acc ->
      case normalize_prefix(prefix) do
        nil -> acc
        normalized -> [normalized | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.sort_by(fn prefix -> {-byte_size(prefix), prefix} end)
  end

  def normalize_prefixes(_), do: @default_prefixes

  @doc """
  Re-tags a parser envelope with a specific parse source.
  """
  @spec with_source(command_envelope(), :body | :mention_stripped) :: command_envelope()
  def with_source(%{source: _} = envelope, source) when source in [:body, :mention_stripped] do
    %{envelope | source: source}
  end

  defp do_parse(nil, _opts, source), do: none_envelope(:empty_text, 0, source)

  defp do_parse(text, opts, source) when is_binary(text) do
    max_text_bytes = max_text_bytes(opts)
    text_bytes = byte_size(text)

    cond do
      text_bytes > max_text_bytes ->
        error_envelope(:text_too_long, nil, text_bytes, source)

      true ->
        parse_bounded(text, text_bytes, normalize_prefixes(Keyword.get(opts, :prefixes)), source)
    end
  end

  defp do_parse(_text, _opts, source), do: error_envelope(:invalid_text, nil, 0, source)

  defp parse_bounded(_text, text_bytes, [], source) do
    error_envelope(:invalid_prefixes, nil, text_bytes, source)
  end

  defp parse_bounded(text, text_bytes, prefixes, source) do
    trimmed = String.trim_leading(text)

    cond do
      trimmed == "" ->
        none_envelope(:empty_text, text_bytes, source)

      true ->
        case Enum.find(prefixes, &String.starts_with?(trimmed, &1)) do
          nil ->
            none_envelope(:not_command, text_bytes, source)

          prefix ->
            parse_prefixed(trimmed, prefix, text_bytes, source)
        end
    end
  end

  defp parse_prefixed(trimmed, prefix, text_bytes, source) do
    rest = String.trim_leading(binary_part(trimmed, byte_size(prefix), byte_size(trimmed) - byte_size(prefix)))

    case String.split(rest, ~r/\s+/, parts: 2, trim: true) do
      [] ->
        error_envelope(:missing_command_name, prefix, text_bytes, source)

      [name] ->
        build_ok_or_error(name, nil, prefix, text_bytes, source)

      [name, args] ->
        build_ok_or_error(name, args, prefix, text_bytes, source)
    end
  end

  defp build_ok_or_error(name, args, prefix, text_bytes, source) do
    if valid_command_name?(name) do
      normalized_name = String.downcase(name)

      %{
        status: :ok,
        source: source,
        prefix: prefix,
        name: normalized_name,
        args: args,
        argv: argv(args),
        reason: nil,
        text_bytes: text_bytes
      }
    else
      error_envelope(:invalid_command_name, prefix, text_bytes, source)
    end
  end

  defp valid_command_name?(name) when is_binary(name) do
    Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, name)
  end

  defp argv(nil), do: []

  defp argv(args) when is_binary(args) do
    String.split(args, ~r/\s+/, trim: true)
  end

  defp error_envelope(reason, prefix, text_bytes, source) do
    %{
      status: :error,
      source: source,
      prefix: prefix,
      name: nil,
      args: nil,
      argv: [],
      reason: reason,
      text_bytes: text_bytes
    }
  end

  defp none_envelope(reason, text_bytes, source) do
    %{
      status: :none,
      source: source,
      prefix: nil,
      name: nil,
      args: nil,
      argv: [],
      reason: reason,
      text_bytes: text_bytes
    }
  end

  defp max_text_bytes(opts) do
    case Keyword.get(opts, :max_text_bytes, @default_max_text_bytes) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_max_text_bytes
    end
  end

  defp normalize_prefix(prefix) when is_binary(prefix) do
    normalized = String.trim(prefix)

    if normalized == "" do
      nil
    else
      normalized
    end
  end

  defp normalize_prefix(_), do: nil
end
