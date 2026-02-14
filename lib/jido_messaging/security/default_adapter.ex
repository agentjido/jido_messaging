defmodule JidoMessaging.Security.DefaultAdapter do
  @moduledoc """
  Default security adapter.

  Behavior:

  - Inbound verify is permissive by default, but denies explicit sender claim
    mismatches and channel-reported authorization failures.
  - Outbound sanitize applies deterministic per-channel text normalization before
    optional channel-specific sanitize hooks.
  """

  @behaviour JidoMessaging.Security

  alias JidoMessaging.Channel

  @doc false
  @impl true
  def verify_sender(channel_module, incoming_message, raw_payload, _opts) do
    with :ok <- verify_sender_claim(incoming_message, raw_payload),
         result <- Channel.verify_sender(channel_module, incoming_message, raw_payload) do
      case result do
        :ok ->
          :ok

        {:ok, metadata} when is_map(metadata) ->
          {:ok, metadata}

        {:error, reason} ->
          case classify_verify_denial(reason) do
            {:deny, denial_reason, description} ->
              {:deny, denial_reason, description}

            nil ->
              {:error, reason}
          end
      end
    end
  end

  @doc false
  @impl true
  def sanitize_outbound(channel_module, outbound, opts) do
    channel_type = channel_module.channel_type()
    baseline = normalize_outbound(channel_type, outbound)

    case Channel.sanitize_outbound(channel_module, baseline, opts) do
      {:ok, sanitized} ->
        {:ok, sanitized,
         %{
           channel_rule: channel_rule(channel_type),
           changed: sanitized != outbound
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_sender_claim(incoming_message, raw_payload) do
    expected_sender = normalize_identity(incoming_message[:external_user_id])
    claimed_sender = extract_claimed_sender(raw_payload)

    cond do
      is_nil(expected_sender) ->
        :ok

      is_nil(claimed_sender) ->
        :ok

      claimed_sender == expected_sender ->
        :ok

      true ->
        {:deny, :sender_claim_mismatch, "Sender identity claim does not match normalized external sender"}
    end
  end

  defp extract_claimed_sender(raw_payload) do
    [
      Map.get(raw_payload, :claimed_sender_id),
      Map.get(raw_payload, "claimed_sender_id"),
      Map.get(raw_payload, :sender_claim),
      Map.get(raw_payload, "sender_claim"),
      Map.get(raw_payload, :sender_id),
      Map.get(raw_payload, "sender_id"),
      nested_sender_id(raw_payload)
    ]
    |> Enum.find_value(&normalize_identity/1)
  end

  defp nested_sender_id(raw_payload) do
    sender_map = Map.get(raw_payload, :sender) || Map.get(raw_payload, "sender")

    cond do
      is_map(sender_map) ->
        Map.get(sender_map, :id) || Map.get(sender_map, "id")

      true ->
        nil
    end
  end

  defp normalize_identity(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_identity(nil), do: nil
  defp normalize_identity(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_identity(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_identity(_value), do: nil

  defp classify_verify_denial(%{} = reason) do
    root = Map.get(reason, :reason) || Map.get(reason, "reason")

    case root do
      :unauthorized_sender ->
        {:deny, :unauthorized_sender, "Sender is not authorized"}

      :forbidden_sender ->
        {:deny, :forbidden_sender, "Sender is forbidden"}

      :untrusted_sender ->
        {:deny, :untrusted_sender, "Sender is untrusted"}

      :denied ->
        {:deny, :denied, "Sender denied by channel verification"}

      _ ->
        nil
    end
  end

  defp normalize_outbound(channel_type, outbound) when is_binary(outbound) do
    outbound
    |> normalize_line_endings()
    |> strip_control_chars()
    |> apply_channel_rule(channel_type)
  end

  defp normalize_outbound(_channel_type, outbound), do: outbound

  defp normalize_line_endings(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp strip_control_chars(text) do
    String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/u, "")
  end

  defp apply_channel_rule(text, :discord) do
    text
    |> String.replace("@everyone", "@ everyone")
    |> String.replace("@here", "@ here")
  end

  defp apply_channel_rule(text, :slack) do
    text
    |> String.replace("<!channel>", "<! channel>")
    |> String.replace("<!here>", "<! here>")
    |> String.replace("<!everyone>", "<! everyone>")
    |> String.replace("@channel", "@ channel")
    |> String.replace("@here", "@ here")
    |> String.replace("@everyone", "@ everyone")
  end

  defp apply_channel_rule(text, _channel_type), do: text

  defp channel_rule(:discord), do: :neutralize_mass_mentions
  defp channel_rule(:slack), do: :neutralize_mass_mentions
  defp channel_rule(_channel_type), do: :default_normalization
end
