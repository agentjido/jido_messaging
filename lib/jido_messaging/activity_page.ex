defmodule Jido.Messaging.ActivityPage do
  @moduledoc false

  alias Jido.Messaging.MessagingActivityEntry

  @doc false
  @spec paginate([MessagingActivityEntry.t()], keyword()) ::
          {:ok, [MessagingActivityEntry.t()]}
          | {:error, :invalid_limit | :invalid_cursor_options | :cursor_not_found}
  def paginate(entries, opts) when is_list(entries) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    entries = Enum.sort_by(entries, &order_key/1)

    if is_integer(limit) and limit > 0 do
      paginate_with_cursor(entries, opts, min(limit, 500))
    else
      {:error, :invalid_limit}
    end
  end

  defp paginate_with_cursor(entries, opts, limit) do
    case cursor_direction(opts) do
      :none ->
        {:ok, Enum.take(entries, -limit)}

      {:before, cursor_id} ->
        with {:ok, cursor} <- find_cursor(entries, cursor_id) do
          {:ok, entries |> Enum.filter(&(order_key(&1) < order_key(cursor))) |> Enum.take(-limit)}
        end

      {:after, cursor_id} ->
        with {:ok, cursor} <- find_cursor(entries, cursor_id) do
          {:ok, entries |> Enum.filter(&(order_key(&1) > order_key(cursor))) |> Enum.take(limit)}
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

  defp find_cursor(entries, cursor_id) do
    case Enum.find(entries, &(&1.id == cursor_id)) do
      nil -> {:error, :cursor_not_found}
      cursor -> {:ok, cursor}
    end
  end

  defp order_key(entry), do: {DateTime.to_iso8601(entry.source_recorded_at), entry.id}
end
