defmodule Jido.Messaging.DeadLetter.RejectionBuffer do
  @moduledoc false

  def new(instance, limit) do
    table = :ets.new(table(instance), [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(table, [{:limit, limit}, {:sequence, 0}])
    table
  end

  def put(instance, record) do
    table = table(instance)

    case :ets.lookup(table, :limit) do
      [{:limit, limit}] ->
        sequence = :ets.update_counter(table, :sequence, 1)
        slot = rem(sequence, limit)
        insert(table, {slot, sequence, record})
        {:ok, record}

      [] ->
        {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def take(instance, batches \\ 1),
    do: take(table(instance), batches, []) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  defp take(_table, 0, records), do: records

  defp take(table, batches, records) do
    case :ets.select(table, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}], 100) do
      :"$end_of_table" ->
        records

      {rows, _cursor} ->
        taken =
          for {slot, sequence, record} <- rows,
              :ets.select_delete(table, [{{slot, sequence, :_}, [], [true]}]) == 1,
              do: {sequence, record}

        take(table, batches - 1, taken ++ records)
    end
  end

  def table(instance), do: Module.concat(instance, DeadLetterRejections)

  defp insert(table, {slot, sequence, _record} = row) do
    if :ets.insert_new(table, row) do
      :ok
    else
      case :ets.lookup(table, slot) do
        [{^slot, previous, _}] when previous >= sequence ->
          :ok

        [{^slot, _, _} = previous] ->
          if :ets.select_replace(table, [{{slot, elem(previous, 1), :_}, [], [{:const, row}]}]) == 1,
            do: :ok,
            else: insert(table, row)

        [] ->
          insert(table, row)
      end
    end
  end
end
