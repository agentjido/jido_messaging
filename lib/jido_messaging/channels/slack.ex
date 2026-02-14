defmodule JidoMessaging.Channels.Slack do
  @moduledoc """
  Slack channel implementation using the Slack Elixir library.

  Handles message transformation and sending for Slack bots.

  ## Usage

  Configure Slack in your app's config:

      # config/runtime.exs or config/dev.secret.exs
      config :slack_elixir,
        token: System.get_env("SLACK_BOT_TOKEN")

  ## Incoming Message Transformation

  Transforms Slack event payloads into normalized JidoMessaging format:

      {:ok, %{
        external_room_id: "C1234567890",
        external_user_id: "U9876543210",
        text: "Hello bot!",
        username: nil,
        display_name: nil,
        external_message_id: "1706745600.123456",
        timestamp: "1706745600.123456",
        chat_type: :channel,
        chat_title: nil
      }}
  """

  use JidoMessaging.Channel

  require Logger

  @doc """
  Returns the configured Slack bot token.

  Override this function or configure via application env:

      config :jido_messaging, :slack_token, "xoxb-..."
  """
  def get_token do
    Application.get_env(:jido_messaging, :slack_token) ||
      Application.get_env(:slack_elixir, :token) ||
      raise "Slack token not configured. Set :jido_messaging, :slack_token or :slack_elixir, :token"
  end

  @impl true
  def channel_type, do: :slack

  @impl true
  def capabilities, do: [:text, :image, :file, :reactions, :threads, :message_edit]

  @impl true
  def transform_incoming(%{event: %{type: "message"} = event}) do
    transform_event(event)
  end

  def transform_incoming(%{"event" => %{"type" => "message"} = event}) do
    transform_event_map(event)
  end

  def transform_incoming(%{type: "message"} = event) do
    transform_event(event)
  end

  def transform_incoming(%{"type" => "message"} = event) do
    transform_event_map(event)
  end

  def transform_incoming(_) do
    {:error, :unsupported_event_type}
  end

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    token = Keyword.get(opts, :token) || get_token()

    payload =
      %{
        channel: channel_id,
        text: text
      }
      |> maybe_add_slack_opt(:thread_ts, opts)
      |> maybe_add_slack_opt(:mrkdwn, opts)
      |> maybe_add_slack_opt(:unfurl_links, opts)
      |> maybe_add_slack_opt(:unfurl_media, opts)

    case Slack.API.post("chat.postMessage", token, payload) do
      {:ok, %{"ok" => true, "ts" => ts, "channel" => channel}} ->
        {:ok,
         %{
           message_id: ts,
           channel_id: channel,
           timestamp: ts
         }}

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.warning("Slack send_message failed: #{error}")
        {:error, error}

      {:error, reason} ->
        Logger.warning("Slack send_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Edit an existing message's text content.

  Used for streaming responses where content is updated incrementally.

  ## Options

  - `:thread_ts` - Thread timestamp for threaded replies
  """
  @impl true
  def edit_message(channel_id, message_ts, text, opts \\ []) do
    token = Keyword.get(opts, :token) || get_token()

    payload =
      %{
        channel: channel_id,
        ts: message_ts,
        text: text
      }
      |> maybe_add_slack_opt(:mrkdwn, opts)

    case Slack.API.post("chat.update", token, payload) do
      {:ok, %{"ok" => true, "ts" => ts, "channel" => channel}} ->
        {:ok,
         %{
           message_id: ts,
           channel_id: channel,
           timestamp: ts
         }}

      {:ok, %{"ok" => false, "error" => error}} ->
        Logger.warning("Slack edit_message failed: #{error}")
        {:error, error}

      {:error, reason} ->
        Logger.warning("Slack edit_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp transform_event(event) when is_map(event) do
    {:ok,
     %{
       external_room_id: Map.get(event, :channel),
       external_user_id: Map.get(event, :user),
       text: Map.get(event, :text),
       media: extract_media(event),
       username: nil,
       display_name: nil,
       external_message_id: Map.get(event, :ts),
       timestamp: Map.get(event, :ts),
       chat_type: parse_channel_type(Map.get(event, :channel_type)),
       chat_title: nil,
       raw: event
     }}
  end

  defp transform_event_map(event) when is_map(event) do
    {:ok,
     %{
       external_room_id: Map.get(event, "channel"),
       external_user_id: Map.get(event, "user"),
       text: Map.get(event, "text"),
       media: extract_media(event),
       username: nil,
       display_name: nil,
       external_message_id: Map.get(event, "ts"),
       timestamp: Map.get(event, "ts"),
       chat_type: parse_channel_type(Map.get(event, "channel_type")),
       chat_title: nil,
       raw: event
     }}
  end

  defp parse_channel_type("channel"), do: :channel
  defp parse_channel_type("group"), do: :group
  defp parse_channel_type("im"), do: :dm
  defp parse_channel_type("mpim"), do: :group_dm
  defp parse_channel_type(:channel), do: :channel
  defp parse_channel_type(:group), do: :group
  defp parse_channel_type(:im), do: :dm
  defp parse_channel_type(:mpim), do: :group_dm
  defp parse_channel_type(_), do: :unknown

  defp maybe_add_slack_opt(payload, key, opts) do
    case Keyword.get(opts, key) do
      nil -> payload
      value -> Map.put(payload, key, value)
    end
  end

  defp extract_media(event) when is_map(event) do
    files = Map.get(event, :files) || Map.get(event, "files")

    case files do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_file/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp extract_media(_), do: []

  defp normalize_file(%_{} = file), do: normalize_file(Map.from_struct(file))

  defp normalize_file(file) when is_map(file) do
    media_type = Map.get(file, :mimetype) || Map.get(file, "mimetype")
    kind = media_kind_from_type(media_type)

    file_ref =
      Map.get(file, :url_private_download) || Map.get(file, "url_private_download") ||
        Map.get(file, :url_private) || Map.get(file, "url_private") ||
        Map.get(file, :permalink) || Map.get(file, "permalink") ||
        slack_file_ref(file)

    if is_nil(file_ref) do
      nil
    else
      %{
        kind: kind,
        url: file_ref,
        media_type: media_type,
        filename: Map.get(file, :name) || Map.get(file, "name"),
        size_bytes: Map.get(file, :size) || Map.get(file, "size")
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end
  end

  defp normalize_file(_), do: nil

  defp slack_file_ref(file) do
    case Map.get(file, :id) || Map.get(file, "id") do
      nil -> nil
      id -> "slack://file/#{id}"
    end
  end

  defp media_kind_from_type(media_type) when is_binary(media_type) do
    cond do
      String.starts_with?(media_type, "image/") -> :image
      String.starts_with?(media_type, "audio/") -> :audio
      String.starts_with?(media_type, "video/") -> :video
      true -> :file
    end
  end

  defp media_kind_from_type(_), do: :file
end
