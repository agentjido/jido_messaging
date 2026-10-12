defmodule Jido.Messaging.MessageLifecycle do
  @moduledoc """
  Applies normalized provider message lifecycle events to persisted messages.

  Messages are resolved by the channel type, bridge ID, provider room, and
  provider message ID. An unknown provider message ID returns `{:ok, :not_found}`. This result is
  safe for late or duplicate delete deliveries and does not create a message.
  """

  alias Jido.Chat.Content.Text
  alias Jido.Messaging.Message

  @type result ::
          {:ok, {:updated, Message.t()}}
          | {:ok, {:deleted, Message.t()}}
          | {:ok, :not_found}
          | {:error, term()}

  @doc """
  Applies an update or delete event to the matching persisted message.

  Successful results identify an updated message, a deleted message, or an
  unknown provider message. Persistence failures pass through as errors.

      iex> classify = fn
      ...>   {:ok, {:updated, %Jido.Messaging.Message{}}} -> :updated
      ...>   {:ok, {:deleted, %Jido.Messaging.Message{}}} -> :deleted
      ...>   {:ok, :not_found} -> :not_found
      ...>   {:error, reason} -> {:error, reason}
      ...> end
      iex> classify.({:ok, :not_found})
      :not_found
      iex> classify.({:error, :database_busy})
      {:error, :database_busy}
  """
  @spec apply(module(), atom(), String.t(), Jido.Signal.t()) :: result()
  def apply(messaging_module, channel_type, bridge_id, %Jido.Signal{type: "jido.chat.message.updated"} = event) do
    with_lifecycle_lock(messaging_module, channel_type, bridge_id, event, fn ->
      apply_update(messaging_module, channel_type, bridge_id, event)
    end)
  end

  def apply(messaging_module, channel_type, bridge_id, %Jido.Signal{type: "jido.chat.message.deleted"} = event) do
    with_lifecycle_lock(messaging_module, channel_type, bridge_id, event, fn ->
      apply_delete(messaging_module, channel_type, bridge_id, event)
    end)
  end

  defp apply_update(messaging_module, channel_type, bridge_id, event) do
    case resolve_message(messaging_module, channel_type, bridge_id, event) do
      {:ok, %Message{} = message} ->
        with :ok <- message_scope(messaging_module, channel_type, bridge_id, message, event) do
          updated_message = update_message(message, event)
          save_updated_message(messaging_module, message, updated_message)
        end

      {:error, :not_found} ->
        {:ok, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_delete(messaging_module, channel_type, bridge_id, event) do
    case resolve_message(messaging_module, channel_type, bridge_id, event) do
      {:ok, %Message{} = message} ->
        with :ok <- message_scope(messaging_module, channel_type, bridge_id, message, event) do
          case messaging_module.delete_message(message.id) do
            :ok -> {:ok, {:deleted, message}}
            {:error, _reason} = error -> error
          end
        end

      {:error, :not_found} ->
        {:ok, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp message_scope(instance, channel, bridge, message, event) do
    with {:ok, room} <- instance.get_room(message.room_id) do
      bindings = Map.get(room.external_bindings, channel, Map.get(room.external_bindings, Atom.to_string(channel), %{}))
      expected = Map.get(bindings, bridge)

      if event.data["room_id"] in [expected, message.delivery_external_room_id],
        do: :ok,
        else: Jido.Chat.Signal.Policy.error(:context_mismatch)
    end
  end

  defp with_lifecycle_lock(messaging_module, channel_type, bridge_id, event, fun) do
    resource = {
      __MODULE__,
      messaging_module,
      channel_type,
      bridge_id,
      event.data["room_id"],
      event.data["message_id"]
    }

    case :global.trans({resource, self()}, fn -> {:lifecycle_result, fun.()} end) do
      {:lifecycle_result, result} -> result
      :aborted -> {:error, :lifecycle_lock_failed}
      {:aborted, reason} -> {:error, {:lifecycle_lock_failed, reason}}
    end
  end

  defp resolve_message(messaging_module, channel_type, bridge_id, event) do
    with {:ok, room} <- messaging_module.get_room_by_external_binding(channel_type, bridge_id, event.data["room_id"]) do
      messaging_module.get_message_by_external_id(
        channel_type,
        bridge_id,
        event.data["message_id"],
        room.id
      )
    end
  end

  defp update_message(%Message{} = message, %Jido.Signal{type: "jido.chat.message.updated"} = event) do
    message
    |> put_updated_content(event.data)
    |> Map.put(:updated_at, lifecycle_timestamp(event, message.updated_at))
  end

  defp save_updated_message(_messaging_module, message, message), do: {:ok, {:updated, message}}

  defp save_updated_message(messaging_module, _message, updated_message) do
    case messaging_module.save_message_struct(updated_message) do
      {:ok, %Message{} = saved_message} -> {:ok, {:updated, saved_message}}
      {:error, _reason} = error -> error
    end
  end

  defp put_updated_content(%Message{} = message, %{"text" => text}) when is_binary(text) do
    %{message | content: replace_text_content(message.content, text)}
  end

  defp put_updated_content(%Message{} = message, _updated_message), do: message

  defp replace_text_content(content, text) when is_list(content) do
    text_content = Text.new(text)

    case Enum.split_while(content, &(not text_content?(&1))) do
      {before, []} ->
        [text_content | before]

      {before, [_old_text | remaining]} ->
        before ++ [text_content | Enum.reject(remaining, &text_content?/1)]
    end
  end

  defp text_content?(%Text{}), do: true
  defp text_content?(%{type: type}) when type in [:text, "text"], do: true
  defp text_content?(%{"type" => type}) when type in [:text, "text"], do: true
  defp text_content?(_content), do: false

  defp lifecycle_timestamp(%Jido.Signal{type: "jido.chat.message.updated"} = event, fallback) do
    event.data
    |> message_timestamp(event.data["timestamp"])
    |> normalize_timestamp(fallback)
  end

  defp message_timestamp(%{updated_at: timestamp}, _event_timestamp) when not is_nil(timestamp),
    do: timestamp

  defp message_timestamp(_message, event_timestamp), do: event_timestamp

  defp normalize_timestamp(%DateTime{} = timestamp, _fallback), do: timestamp

  defp normalize_timestamp(timestamp, fallback) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      {:error, _reason} -> fallback || DateTime.utc_now()
    end
  end

  defp normalize_timestamp(_timestamp, fallback), do: fallback || DateTime.utc_now()
end
