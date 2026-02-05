defmodule JidoMessaging.Adapters.Mentions do
  @moduledoc """
  Behaviour for channel-specific mention detection and parsing.

  Mention detection varies significantly across platforms. This behaviour defines
  how channels can implement platform-specific mention parsing while providing
  normalized output for the messaging pipeline.

  ## Mention Structure

  Parsed mentions follow a consistent structure:

      %{
        user_id: "123456789",      # Platform's user ID
        username: "johndoe",       # Username (may be nil)
        offset: 0,                 # Byte offset in the message body
        length: 8                  # Length of the mention text
      }

  ## Implementation

  Channels should implement this behaviour to enable mention detection:

      defmodule MyApp.Channels.Telegram.Mentions do
        @behaviour JidoMessaging.Adapters.Mentions

        @impl true
        def parse_mentions(body, raw) do
          entities = raw["entities"] || []

          entities
          |> Enum.filter(&(&1["type"] == "mention" or &1["type"] == "text_mention"))
          |> Enum.map(fn entity ->
            %{
              user_id: to_string(entity["user"]["id"]),
              username: entity["user"]["username"],
              offset: entity["offset"],
              length: entity["length"]
            }
          end)
        end

        @impl true
        def was_mentioned?(raw, bot_id) do
          entities = raw["entities"] || []
          Enum.any?(entities, fn e ->
            e["type"] == "text_mention" and to_string(e["user"]["id"]) == bot_id
          end)
        end
      end

  ## Integration with MsgContext

  The `MsgContext` struct includes fields populated by mention adapters:

    * `was_mentioned` - Boolean indicating if the bot was mentioned
    * `mentions` - List of parsed mention maps

  ## Default Implementations

  All callbacks are optional:

    * `parse_mentions/2` - Returns `[]` if not implemented
    * `strip_mentions/2` - Returns the original body if not implemented
    * `was_mentioned?/2` - Returns `false` if not implemented
  """

  @type mention :: %{
          user_id: String.t(),
          username: String.t() | nil,
          offset: non_neg_integer(),
          length: non_neg_integer()
        }

  @doc """
  Parses mentions from a message body and raw payload.

  ## Parameters

    * `body` - The text content of the message
    * `raw` - The raw platform-specific message payload

  ## Returns

  A list of mention maps with `:user_id`, `:username`, `:offset`, and `:length`.
  """
  @callback parse_mentions(body :: String.t(), raw :: map()) :: [mention()]

  @doc """
  Strips mentions from a message body.

  Useful for getting clean text content without mention markers.

  ## Parameters

    * `body` - The text content of the message
    * `mentions` - List of parsed mentions from `parse_mentions/2`

  ## Returns

  The message body with mention text removed or replaced.
  """
  @callback strip_mentions(body :: String.t(), mentions :: [mention()]) :: String.t()

  @doc """
  Checks if the bot was mentioned in the message.

  ## Parameters

    * `raw` - The raw platform-specific message payload
    * `bot_id` - The bot's user ID on the platform

  ## Returns

  `true` if the bot was mentioned, `false` otherwise.
  """
  @callback was_mentioned?(raw :: map(), bot_id :: String.t()) :: boolean()

  @optional_callbacks strip_mentions: 2

  @doc """
  Safely parses mentions for a module.

  Returns an empty list if the module doesn't implement the callback.
  """
  @spec parse_mentions(module(), String.t(), map()) :: [mention()]
  def parse_mentions(module, body, raw) when is_binary(body) and is_map(raw) do
    if function_exported?(module, :parse_mentions, 2) do
      module.parse_mentions(body, raw)
    else
      []
    end
  end

  @doc """
  Safely strips mentions for a module.

  Returns the original body if the module doesn't implement the callback.
  """
  @spec strip_mentions(module(), String.t(), [mention()]) :: String.t()
  def strip_mentions(module, body, mentions) when is_binary(body) and is_list(mentions) do
    if function_exported?(module, :strip_mentions, 2) do
      module.strip_mentions(body, mentions)
    else
      body
    end
  end

  @doc """
  Safely checks if the bot was mentioned for a module.

  Returns `false` if the module doesn't implement the callback.
  """
  @spec was_mentioned?(module(), map(), String.t()) :: boolean()
  def was_mentioned?(module, raw, bot_id) when is_map(raw) and is_binary(bot_id) do
    if function_exported?(module, :was_mentioned?, 2) do
      module.was_mentioned?(raw, bot_id)
    else
      false
    end
  end

  @doc """
  Checks if a module implements the Mentions behaviour.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) do
    function_exported?(module, :parse_mentions, 2) or
      function_exported?(module, :was_mentioned?, 2)
  end

  @doc """
  Default implementation for stripping mentions from text.

  Removes mention text by offset/length, processing from end to start
  to preserve offsets.

  ## Examples

      mentions = [%{offset: 0, length: 5, user_id: "1", username: nil}]
      Mentions.default_strip_mentions("@john hello", mentions)
      # => " hello"
  """
  @spec default_strip_mentions(String.t(), [mention()]) :: String.t()
  def default_strip_mentions(body, mentions) when is_binary(body) and is_list(mentions) do
    mentions
    |> Enum.sort_by(& &1.offset, :desc)
    |> Enum.reduce(body, fn %{offset: offset, length: length}, acc ->
      before = binary_part(acc, 0, offset)
      after_mention = binary_part(acc, offset + length, byte_size(acc) - offset - length)
      before <> after_mention
    end)
  end
end
