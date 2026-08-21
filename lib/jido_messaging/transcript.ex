defmodule Jido.Messaging.Transcript do
  @moduledoc false

  alias Jido.Messaging.Message

  @spec paginate([Message.t()], keyword()) :: {:ok, [Message.t()]} | {:error, term()}
  def paginate(messages, opts) when is_list(messages) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    messages = Enum.sort_by(messages, &order_key/1)

    if is_integer(limit) and limit > 0 do
      paginate_with_cursor(messages, opts, limit)
    else
      {:error, :invalid_limit}
    end
  end

  defp paginate_with_cursor(messages, opts, limit) do
    case cursor_direction(opts) do
      :none ->
        {:ok, Enum.take(messages, -limit)}

      {:before, cursor_id} ->
        with {:ok, cursor} <- find_cursor(messages, cursor_id) do
          page = messages |> Enum.filter(&(order_key(&1) < order_key(cursor))) |> Enum.take(-limit)
          {:ok, page}
        end

      {:after, cursor_id} ->
        with {:ok, cursor} <- find_cursor(messages, cursor_id) do
          page = messages |> Enum.filter(&(order_key(&1) > order_key(cursor))) |> Enum.take(limit)
          {:ok, page}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cursor_direction(opts) do
    case {Keyword.get(opts, :before), Keyword.get(opts, :after)} do
      {nil, nil} -> :none
      {before, nil} when is_binary(before) and before != "" -> {:before, before}
      {nil, after_cursor} when is_binary(after_cursor) and after_cursor != "" -> {:after, after_cursor}
      {_before, _after_cursor} -> {:error, :invalid_cursor_options}
    end
  end

  defp find_cursor(messages, cursor_id) do
    case Enum.find(messages, &(&1.id == cursor_id)) do
      nil -> {:error, :cursor_not_found}
      cursor -> {:ok, cursor}
    end
  end

  defp order_key(%Message{inserted_at: %DateTime{} = inserted_at, id: id}) do
    {DateTime.to_iso8601(inserted_at), id}
  end

  defp order_key(%Message{id: id}), do: {"", id}
end
