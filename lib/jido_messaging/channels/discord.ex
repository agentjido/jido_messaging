defmodule JidoMessaging.Channels.Discord do
  @moduledoc """
  Discord channel implementation using the Nostrum library.

  Handles message transformation and sending for Discord bots.

  ## Usage

  Configure Nostrum in your app's config:

      # config/config.exs
      config :nostrum,
        token: System.get_env("DISCORD_BOT_TOKEN"),
        gateway_intents: [:guilds, :guild_messages, :message_content]

  ## Incoming Message Transformation

  Transforms Nostrum Message structs into normalized JidoMessaging format:

      {:ok, %{
        external_room_id: 123456789012345678,
        external_user_id: 987654321098765432,
        text: "Hello bot!",
        username: "john_doe",
        display_name: "John",
        external_message_id: 111222333444555666,
        timestamp: ~U[2024-01-31 12:00:00.000000Z],
        chat_type: :guild,
        chat_title: "general"
      }}
  """

  use JidoMessaging.Channel

  require Logger

  @impl true
  def channel_type, do: :discord

  @impl true
  def capabilities, do: [:text, :image, :audio, :video, :file, :reactions, :threads, :message_edit]

  @impl true
  def transform_incoming(%Nostrum.Struct.Message{} = msg) do
    {:ok,
     %{
       external_room_id: msg.channel_id,
       external_user_id: get_user_id(msg),
       text: msg.content,
       media: extract_media(msg),
       username: get_username(msg),
       display_name: get_display_name(msg),
       external_message_id: msg.id,
       timestamp: msg.timestamp,
       chat_type: parse_chat_type(msg),
       chat_title: nil,
       raw: Map.from_struct(msg)
     }}
  end

  def transform_incoming(%{channel_id: channel_id} = msg) when is_map(msg) do
    {:ok,
     %{
       external_room_id: channel_id,
       external_user_id: get_map_value(msg, [:author, "author"]) |> get_nested_id(),
       text: get_map_value(msg, [:content, "content"]),
       media: extract_media(msg),
       username: get_map_value(msg, [:author, "author"]) |> get_nested_username(),
       display_name: get_map_value(msg, [:author, "author"]) |> get_nested_display_name(),
       external_message_id: get_map_value(msg, [:id, "id"]),
       timestamp: get_map_value(msg, [:timestamp, "timestamp"]),
       chat_type: parse_map_chat_type(msg),
       chat_title: nil,
       raw: msg
     }}
  end

  def transform_incoming(%{"channel_id" => channel_id} = msg) when is_map(msg) do
    {:ok,
     %{
       external_room_id: channel_id,
       external_user_id: get_map_value(msg, [:author, "author"]) |> get_nested_id(),
       text: get_map_value(msg, [:content, "content"]),
       media: extract_media(msg),
       username: get_map_value(msg, [:author, "author"]) |> get_nested_username(),
       display_name: get_map_value(msg, [:author, "author"]) |> get_nested_display_name(),
       external_message_id: get_map_value(msg, [:id, "id"]),
       timestamp: get_map_value(msg, [:timestamp, "timestamp"]),
       chat_type: parse_map_chat_type(msg),
       chat_title: nil,
       raw: msg
     }}
  end

  def transform_incoming(_) do
    {:error, :unsupported_message_type}
  end

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    # Ensure channel_id is an integer (Nostrum requires this)
    channel_id = to_integer(channel_id)
    message_opts = build_message_opts(text, opts)

    case apply(Nostrum.Api.Message, :create, [channel_id, message_opts]) do
      {:ok, sent_message} ->
        {:ok,
         %{
           message_id: sent_message.id,
           channel_id: sent_message.channel_id,
           timestamp: sent_message.timestamp
         }}

      {:error, reason} ->
        Logger.warning("Discord send_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Edit an existing message's text content.

  Used for streaming responses where content is updated incrementally.

  ## Options

  - `:embeds` - List of embed objects to include
  """
  @impl true
  def edit_message(channel_id, message_id, text, opts \\ []) do
    edit_opts = build_edit_opts(text, opts)

    case apply(Nostrum.Api.Message, :edit, [channel_id, message_id, edit_opts]) do
      {:ok, edited_message} ->
        {:ok,
         %{
           message_id: edited_message.id,
           channel_id: edited_message.channel_id,
           timestamp: edited_message.edited_timestamp || edited_message.timestamp
         }}

      {:error, reason} ->
        Logger.warning("Discord edit_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp get_user_id(%{author: %{id: id}}), do: id
  defp get_user_id(_), do: nil

  defp get_username(%{author: %{username: username}}), do: username
  defp get_username(_), do: nil

  defp get_display_name(%{author: %{global_name: global_name}}) when not is_nil(global_name),
    do: global_name

  defp get_display_name(%{author: %{username: username}}), do: username
  defp get_display_name(_), do: nil

  defp get_map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_nested_id(nil), do: nil
  defp get_nested_id(author) when is_map(author), do: get_map_value(author, [:id, "id"])

  defp get_nested_username(nil), do: nil

  defp get_nested_username(author) when is_map(author),
    do: get_map_value(author, [:username, "username"])

  defp get_nested_display_name(nil), do: nil

  defp get_nested_display_name(author) when is_map(author) do
    get_map_value(author, [:global_name, "global_name"]) ||
      get_map_value(author, [:username, "username"])
  end

  defp parse_chat_type(%{guild_id: nil}), do: :dm
  defp parse_chat_type(%{guild_id: _}), do: :guild
  defp parse_chat_type(_), do: :unknown

  defp parse_map_chat_type(msg) when is_map(msg) do
    guild_id = get_map_value(msg, [:guild_id, "guild_id"])
    if guild_id, do: :guild, else: :dm
  end

  defp extract_media(%Nostrum.Struct.Message{attachments: attachments}) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_media(msg) when is_map(msg) do
    msg
    |> get_map_value([:attachments, "attachments"])
    |> normalize_attachments()
  end

  defp normalize_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_attachments(_), do: []

  defp normalize_attachment(%_{} = attachment) do
    attachment
    |> Map.from_struct()
    |> normalize_attachment()
  end

  defp normalize_attachment(attachment) when is_map(attachment) do
    media_type = get_map_value(attachment, [:content_type, "content_type"])
    filename = get_map_value(attachment, [:filename, "filename", :name, "name"])
    url = get_map_value(attachment, [:url, "url", :proxy_url, "proxy_url"])
    kind = attachment_kind(media_type)

    %{
      kind: kind,
      url: url,
      media_type: media_type,
      filename: filename,
      size_bytes: get_map_value(attachment, [:size, "size"]),
      width: get_map_value(attachment, [:width, "width"]),
      height: get_map_value(attachment, [:height, "height"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_attachment(_), do: nil

  defp attachment_kind(media_type) when is_binary(media_type) do
    cond do
      String.starts_with?(media_type, "image/") -> :image
      String.starts_with?(media_type, "audio/") -> :audio
      String.starts_with?(media_type, "video/") -> :video
      true -> :file
    end
  end

  defp attachment_kind(_), do: :file

  defp build_message_opts(text, opts) do
    base = %{content: text}

    base
    |> maybe_add_opt(:embeds, opts)
    |> maybe_add_opt(:components, opts)
    |> maybe_add_opt(:tts, opts)
    |> maybe_add_opt(:allowed_mentions, opts)
    |> maybe_add_opt(:message_reference, opts)
  end

  defp build_edit_opts(text, opts) do
    base = %{content: text}

    base
    |> maybe_add_opt(:embeds, opts)
    |> maybe_add_opt(:components, opts)
    |> maybe_add_opt(:allowed_mentions, opts)
  end

  defp maybe_add_opt(map, key, opts) do
    case Keyword.get(opts, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)
end
