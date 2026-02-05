defmodule JidoMessaging.Demo.DiscordHandler do
  @moduledoc """
  Demo Discord handler.

  Bridge forwarding is now handled via Signal Bus subscription in the Bridge module.
  This handler just logs incoming messages and returns :noreply.
  """
  use JidoMessaging.Channels.Discord.Handler,
    messaging: JidoMessaging.Demo.Messaging,
    on_message: &JidoMessaging.Demo.DiscordHandler.handle_message/2

  require Logger

  @doc """
  Handle incoming Discord messages.

  The message has already been ingested (persisted, added to RoomServer) by the
  channel handler infrastructure. RoomServer emits a signal which the Bridge
  receives and forwards to Telegram.
  """
  def handle_message(message, context) do
    text = extract_text(message)
    username = get_username_from_context(context)
    channel_id = context[:external_room_id]

    Logger.info("[Demo.Discord] Channel: #{channel_id}, User: #{username}")
    Logger.info("[Demo.Discord] Received: #{text}")

    # Bridge forwarding removed - handled by Signal Bus subscriber
    :noreply
  end

  defp extract_text(%{content: [%{text: text} | _]}) when is_binary(text), do: text
  defp extract_text(%{content: [%{"text" => text} | _]}) when is_binary(text), do: text

  defp extract_text(%{content: content}) when is_list(content) do
    Enum.find_value(content, fn
      %{type: :text, text: text} -> text
      %{"type" => "text", "text" => text} -> text
      %JidoMessaging.Content.Text{text: text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: nil

  defp get_username_from_context(%{participant: %{identity: identity}}) do
    identity[:username] || identity[:display_name] || "unknown"
  end

  defp get_username_from_context(_), do: "unknown"
end
