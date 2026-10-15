defmodule Jido.Messaging.AdapterBridge.Media do
  @moduledoc false
  alias Jido.Chat.{FileUpload, PostPayload}

  def stage_options(opts, stage) do
    case opts[:request_id] do
      id when is_binary(id) ->
        stage_id = :crypto.hash(:sha256, :erlang.term_to_binary({:media_replacement, id, stage}))
        Keyword.put(opts, :request_id, "media:" <> Base.url_encode64(stage_id, padding: false))

      _ ->
        opts
    end
  end

  def resource(binding, file, nil), do: Jido.Chat.put_resource(binding, "file", file)

  def resource(binding, file, request_id) do
    key = {:messaging_media_resource, request_id}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(file, [:deterministic]))

    case Jido.Chat.RequestStore.claim(binding, key, digest) do
      {:ok, {:cached, result}} ->
        result

      {:ok, {:claimed, claim}} ->
        result = Jido.Chat.put_resource(binding, "file", file)

        case Jido.Chat.RequestStore.complete(binding, claim, result) do
          :ok -> result
          error -> error
        end

      error ->
        error
    end
  end

  def payload(payload) when is_map(payload) do
    metadata = media_payload_metadata(payload)

    file =
      FileUpload.new(%{
        kind: media_kind(payload[:kind] || payload["kind"]),
        url: payload[:url] || payload["url"],
        path: payload[:path] || payload["path"],
        data: payload[:data] || payload["data"],
        media_type: payload[:media_type] || payload["media_type"],
        filename: payload[:filename] || payload["filename"],
        size_bytes: payload[:size_bytes] || payload["size_bytes"],
        width: payload[:width] || payload["width"],
        height: payload[:height] || payload["height"],
        duration: payload[:duration] || payload["duration"],
        metadata: metadata
      })

    attrs =
      %{
        files: [file],
        metadata: metadata
      }
      |> maybe_put_post_text(media_payload_caption(payload))

    PostPayload.new(attrs)
  end

  defp media_kind(kind) when is_binary(kind),
    do: Enum.find([:image, :audio, :video, :file], kind, &(Atom.to_string(&1) == kind))

  defp media_kind(kind), do: kind

  defp media_payload_metadata(payload) when is_map(payload) do
    (payload[:metadata] || payload["metadata"] || %{})
    |> maybe_put_map_value(:thumbnail_url, payload[:thumbnail_url] || payload["thumbnail_url"])
    |> maybe_put_map_value(:alt_text, payload[:alt_text] || payload["alt_text"])
    |> maybe_put_map_value(:transcript, payload[:transcript] || payload["transcript"])
  end

  defp media_payload_caption(payload) when is_map(payload) do
    payload[:alt_text] || payload["alt_text"] || payload[:transcript] || payload["transcript"]
  end

  defp maybe_put_post_text(attrs, nil), do: attrs
  defp maybe_put_post_text(attrs, ""), do: attrs

  defp maybe_put_post_text(attrs, text) when is_binary(text) do
    Map.merge(attrs, %{text: text, formatted: text, fallback_text: text})
  end

  def replacement(result, replaced_message_id, delete_result) when is_map(result) do
    metadata =
      result
      |> Map.get(:metadata, %{})
      |> Map.put(:replacement, replacement_metadata(replaced_message_id, delete_result))

    result
    |> Map.put(:metadata, metadata)
    |> Map.put(:status, :edited)
  end

  defp replacement_metadata(replaced_message_id, {:ok, _ack}) do
    %{
      replaced_message_id: replaced_message_id,
      delete_status: :deleted
    }
  end

  defp replacement_metadata(replaced_message_id, {:error, reason}) do
    %{
      replaced_message_id: replaced_message_id,
      delete_status: :delete_failed,
      delete_reason: reason
    }
  end

  defp maybe_put_map_value(map, _key, nil), do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)
end
