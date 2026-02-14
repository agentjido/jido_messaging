defmodule JidoMessaging.Channels.WhatsApp do
  @moduledoc """
  WhatsApp channel implementation using the WhatsApp Elixir library.

  Handles message transformation and sending for WhatsApp Business API.

  ## Usage

  Configure WhatsApp in your app's config:

      # config/runtime.exs or config/dev.secret.exs
      config :whatsapp_elixir,
        token: System.get_env("WHATSAPP_ACCESS_TOKEN"),
        phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID")

  ## Incoming Message Transformation

  Transforms WhatsApp webhook payloads into normalized JidoMessaging format:

      {:ok, %{
        external_room_id: "15551234567",
        external_user_id: "15551234567",
        text: "Hello bot!",
        username: nil,
        display_name: "John Doe",
        external_message_id: "wamid.HBgLMTU1NTEyMzQ1NjcVAgASGBQzQTRCNUY...",
        timestamp: "1706745600",
        chat_type: :private,
        chat_title: nil
      }}
  """

  use JidoMessaging.Channel

  require Logger

  @impl true
  def channel_type, do: :whatsapp

  @impl true
  def capabilities, do: [:text, :image, :audio, :video, :file]

  @impl true
  def transform_incoming(%{
        "entry" => [%{"changes" => [%{"value" => %{"messages" => [message | _]} = value} | _]} | _]
      }) do
    transform_webhook_message(message, value)
  end

  def transform_incoming(%{
        entry: [%{changes: [%{value: %{messages: [message | _]} = value} | _]} | _]
      }) do
    transform_webhook_message_struct(message, value)
  end

  def transform_incoming(%{"from" => _from} = message) do
    transform_direct_message(message)
  end

  def transform_incoming(%{from: _from} = message) do
    transform_direct_message_struct(message)
  end

  def transform_incoming(_) do
    {:error, :unsupported_webhook_payload}
  end

  @impl true
  def send_message(phone_number, text, opts \\ []) do
    recipient = normalize_phone_number(phone_number)

    message_payload = build_text_message(recipient, text, opts)

    case WhatsappElixir.Messages.send_message(message_payload, []) do
      {:ok, %{"messages" => [%{"id" => message_id} | _]}} ->
        {:ok,
         %{
           message_id: message_id,
           recipient: recipient,
           timestamp: System.system_time(:second)
         }}

      {:ok, response} ->
        {:ok, %{message_id: nil, recipient: recipient, raw_response: response}}

      {:error, reason} ->
        Logger.warning("WhatsApp send_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp transform_webhook_message(message, value) do
    contact = get_contact_from_value(value)

    {:ok,
     %{
       external_room_id: Map.get(message, "from"),
       external_user_id: Map.get(message, "from"),
       text: get_text_content(message),
       username: nil,
       display_name: get_contact_name(contact),
       external_message_id: Map.get(message, "id"),
       timestamp: Map.get(message, "timestamp"),
       chat_type: :private,
       chat_title: nil
     }}
  end

  defp transform_webhook_message_struct(message, value) do
    contact = get_contact_from_value_struct(value)

    {:ok,
     %{
       external_room_id: Map.get(message, :from),
       external_user_id: Map.get(message, :from),
       text: get_text_content_struct(message),
       username: nil,
       display_name: get_contact_name_struct(contact),
       external_message_id: Map.get(message, :id),
       timestamp: Map.get(message, :timestamp),
       chat_type: :private,
       chat_title: nil
     }}
  end

  defp transform_direct_message(message) do
    {:ok,
     %{
       external_room_id: Map.get(message, "from"),
       external_user_id: Map.get(message, "from"),
       text: get_text_content(message),
       username: nil,
       display_name: nil,
       external_message_id: Map.get(message, "id"),
       timestamp: Map.get(message, "timestamp"),
       chat_type: :private,
       chat_title: nil
     }}
  end

  defp transform_direct_message_struct(message) do
    {:ok,
     %{
       external_room_id: Map.get(message, :from),
       external_user_id: Map.get(message, :from),
       text: get_text_content_struct(message),
       username: nil,
       display_name: nil,
       external_message_id: Map.get(message, :id),
       timestamp: Map.get(message, :timestamp),
       chat_type: :private,
       chat_title: nil
     }}
  end

  defp get_contact_from_value(%{"contacts" => [contact | _]}), do: contact
  defp get_contact_from_value(_), do: nil

  defp get_contact_from_value_struct(%{contacts: [contact | _]}), do: contact
  defp get_contact_from_value_struct(_), do: nil

  defp get_contact_name(nil), do: nil
  defp get_contact_name(%{"profile" => %{"name" => name}}), do: name
  defp get_contact_name(_), do: nil

  defp get_contact_name_struct(nil), do: nil
  defp get_contact_name_struct(%{profile: %{name: name}}), do: name
  defp get_contact_name_struct(_), do: nil

  defp get_text_content(%{"type" => "text", "text" => %{"body" => body}}), do: body
  defp get_text_content(%{"text" => %{"body" => body}}), do: body
  defp get_text_content(_), do: nil

  defp get_text_content_struct(%{type: "text", text: %{body: body}}), do: body
  defp get_text_content_struct(%{text: %{body: body}}), do: body
  defp get_text_content_struct(_), do: nil

  defp normalize_phone_number(phone) when is_binary(phone) do
    phone
    |> String.replace(~r/[^\d]/, "")
  end

  defp normalize_phone_number(phone) when is_integer(phone), do: Integer.to_string(phone)
  defp normalize_phone_number(phone), do: to_string(phone)

  defp build_text_message(recipient, text, _opts) do
    %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: recipient,
      type: "text",
      text: %{
        preview_url: false,
        body: text
      }
    }
  end
end
