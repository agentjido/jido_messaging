defmodule JidoMessaging.Moderators.RateLimiter do
  @moduledoc """
  Rate limiting moderator to prevent message flooding.

  Uses ETS to track message counts per sender within a time window.

  ## Options

  - `:max_messages` - Maximum messages allowed in window (default: 10)
  - `:window_ms` - Time window in milliseconds (default: 60_000 = 1 minute)
  - `:table` - ETS table name for tracking (default: :jido_messaging_rate_limits)

  ## Example

      RateLimiter.moderate(message, max_messages: 5, window_ms: 30_000)
  """

  @behaviour JidoMessaging.Moderation

  @default_table :jido_messaging_rate_limits
  @default_max_messages 10
  @default_window_ms 60_000

  @impl true
  def moderate(message, opts) do
    table = Keyword.get(opts, :table, @default_table)
    max_messages = Keyword.get(opts, :max_messages, @default_max_messages)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    ensure_table_exists(table)

    sender_id = message.sender_id
    now = System.monotonic_time(:millisecond)
    window_start = now - window_ms

    cleanup_old_entries(table, sender_id, window_start)

    count = count_messages(table, sender_id, window_start)

    if count >= max_messages do
      {:reject, :rate_limited, "Rate limit exceeded: #{max_messages} messages per #{div(window_ms, 1000)} seconds"}
    else
      record_message(table, sender_id, now)
      :allow
    end
  end

  @doc """
  Initialize the rate limiter ETS table.

  Call this during application startup if you want to control table creation.
  """
  def init(table \\ @default_table) do
    ensure_table_exists(table)
  end

  @doc """
  Reset rate limit counters for a sender.
  """
  def reset(sender_id, table \\ @default_table) do
    if :ets.whereis(table) != :undefined do
      :ets.match_delete(table, {sender_id, :_})
    end

    :ok
  end

  @doc """
  Get current message count for a sender within the window.
  """
  def get_count(sender_id, opts \\ []) do
    table = Keyword.get(opts, :table, @default_table)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    if :ets.whereis(table) == :undefined do
      0
    else
      now = System.monotonic_time(:millisecond)
      window_start = now - window_ms
      count_messages(table, sender_id, window_start)
    end
  end

  defp ensure_table_exists(table) do
    if :ets.whereis(table) == :undefined do
      try do
        :ets.new(table, [:duplicate_bag, :public, :named_table])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  defp cleanup_old_entries(table, sender_id, window_start) do
    :ets.select_delete(table, [{{sender_id, :"$1"}, [{:<, :"$1", window_start}], [true]}])
  end

  defp count_messages(table, sender_id, window_start) do
    :ets.select_count(table, [{{sender_id, :"$1"}, [{:>=, :"$1", window_start}], [true]}])
  end

  defp record_message(table, sender_id, timestamp) do
    :ets.insert(table, {sender_id, timestamp})
  end
end
