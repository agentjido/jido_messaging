defmodule Jido.Messaging.Query do
  @moduledoc """
  Low-level query helpers for canonical `Jido.Messaging` records.

  These helpers intentionally return messaging structs, not UI maps. Apps can
  build their own chat contexts and projections while reusing common timeline
  and thread grouping behavior.
  """

  alias Jido.Messaging.Message

  @type room_timeline :: %{
          messages: [Message.t()],
          threads: %{optional(String.t()) => [Message.t()]},
          reply_counts: %{optional(String.t()) => non_neg_integer()}
        }

  @spec room_timeline([Message.t()]) :: room_timeline()
  def room_timeline(messages) when is_list(messages) do
    messages = Enum.sort_by(messages, & &1.inserted_at, {:asc, DateTime})
    {replies, timeline} = Enum.split_with(messages, &is_binary(&1.thread_id))
    threads = Enum.group_by(replies, & &1.thread_id)

    reply_counts =
      Map.new(timeline, fn message ->
        {message.id, threads |> Map.get(message.id, []) |> Enum.count()}
      end)

    %{messages: timeline, threads: threads, reply_counts: reply_counts}
  end
end
