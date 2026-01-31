defmodule JidoMessaging.Channels.Telegram do
  @moduledoc """
  Telegram channel implementation using the Telegex library.

  Handles message transformation and sending for Telegram bots.

  ## Usage

  Configure Telegex in your app's config:

      # config/config.exs
      config :telegex, caller_adapter: Telegex.Caller.Adapter.Finch

      # config/runtime.exs or config/dev.secret.exs
      config :telegex, token: System.get_env("TELEGRAM_BOT_TOKEN")

  ## Incoming Message Transformation

  Transforms Telegram Update structs into normalized JidoMessaging format:

      {:ok, %{
        external_room_id: 123456789,
        external_user_id: 987654321,
        text: "Hello bot!",
        username: "john_doe",
        display_name: "John",
        external_message_id: 42,
        timestamp: 1706745600,
        chat_type: :private,
        chat_title: nil
      }}
  """

  @behaviour JidoMessaging.Channel

  require Logger

  @impl true
  def channel_type, do: :telegram

  @impl true
  def transform_incoming(%Telegex.Type.Update{message: nil}) do
    {:error, :no_message}
  end

  def transform_incoming(%Telegex.Type.Update{message: message}) do
    transform_message(message)
  end

  def transform_incoming(%{message: nil}) do
    {:error, :no_message}
  end

  def transform_incoming(%{message: message}) when is_map(message) do
    transform_message_map(message)
  end

  def transform_incoming(%{"message" => nil}) do
    {:error, :no_message}
  end

  def transform_incoming(%{"message" => message}) when is_map(message) do
    transform_message_map(message)
  end

  def transform_incoming(_) do
    {:error, :unsupported_update_type}
  end

  @impl true
  def send_message(chat_id, text, opts \\ []) do
    telegram_opts = build_telegram_opts(opts)

    case Telegex.send_message(chat_id, text, telegram_opts) do
      {:ok, sent_message} ->
        {:ok,
         %{
           message_id: sent_message.message_id,
           chat_id: sent_message.chat.id,
           date: sent_message.date
         }}

      {:error, reason} ->
        Logger.warning("Telegram send_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Edit an existing message's text content.

  Used for streaming responses where content is updated incrementally.

  ## Options

  - `:parse_mode` - "Markdown", "MarkdownV2", or "HTML"
  """
  def edit_message(chat_id, message_id, text, opts \\ []) do
    telegram_opts =
      opts
      |> build_telegram_opts()
      |> Keyword.put(:chat_id, chat_id)
      |> Keyword.put(:message_id, message_id)

    case Telegex.edit_message_text(text, telegram_opts) do
      {:ok, %Telegex.Type.Message{} = edited_message} ->
        {:ok,
         %{
           message_id: edited_message.message_id,
           chat_id: edited_message.chat.id,
           date: edited_message.date
         }}

      {:ok, true} ->
        {:ok, %{message_id: message_id, chat_id: chat_id, date: nil}}

      {:error, reason} ->
        Logger.warning("Telegram edit_message_text failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp transform_message(%Telegex.Type.Message{} = msg) do
    {:ok,
     %{
       external_room_id: msg.chat.id,
       external_user_id: get_user_id(msg),
       text: msg.text,
       username: get_username(msg),
       display_name: get_display_name(msg),
       external_message_id: msg.message_id,
       timestamp: msg.date,
       chat_type: parse_chat_type(msg.chat.type),
       chat_title: msg.chat.title
     }}
  end

  defp transform_message_map(msg) when is_map(msg) do
    chat = Map.get(msg, :chat) || Map.get(msg, "chat", %{})
    from = Map.get(msg, :from) || Map.get(msg, "from", %{})

    {:ok,
     %{
       external_room_id: get_map_value(chat, [:id, "id"]),
       external_user_id: get_map_value(from, [:id, "id"]),
       text: get_map_value(msg, [:text, "text"]),
       username: get_map_value(from, [:username, "username"]),
       display_name: get_map_value(from, [:first_name, "first_name"]),
       external_message_id: get_map_value(msg, [:message_id, "message_id"]),
       timestamp: get_map_value(msg, [:date, "date"]),
       chat_type: parse_chat_type(get_map_value(chat, [:type, "type"])),
       chat_title: get_map_value(chat, [:title, "title"])
     }}
  end

  defp get_user_id(%{from: %{id: id}}), do: id
  defp get_user_id(_), do: nil

  defp get_username(%{from: %{username: username}}), do: username
  defp get_username(_), do: nil

  defp get_display_name(%{from: %{first_name: first_name}}), do: first_name
  defp get_display_name(_), do: nil

  defp get_map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_map_value(_, _), do: nil

  defp parse_chat_type("private"), do: :private
  defp parse_chat_type("group"), do: :group
  defp parse_chat_type("supergroup"), do: :supergroup
  defp parse_chat_type("channel"), do: :channel
  defp parse_chat_type(:private), do: :private
  defp parse_chat_type(:group), do: :group
  defp parse_chat_type(:supergroup), do: :supergroup
  defp parse_chat_type(:channel), do: :channel
  defp parse_chat_type(_), do: :unknown

  defp build_telegram_opts(opts) do
    opts
    |> Keyword.take([:parse_mode, :reply_to_message_id, :disable_notification, :reply_markup])
  end
end
