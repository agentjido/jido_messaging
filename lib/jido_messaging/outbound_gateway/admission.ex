defmodule Jido.Messaging.OutboundGateway.Admission do
  @moduledoc false

  def new(instance), do: :ets.new(table(instance), [:named_table, :public, :set, read_concurrency: true])
  def table(instance), do: Module.concat(instance, GatewayAdmission)

  def open(instance, partition, config) do
    epoch = make_ref()
    :ets.insert(table(instance), {partition, self(), epoch, config, 0, %{}})
    epoch
  end

  def snapshot(instance, partition, coordinator) do
    case :ets.lookup(table(instance), partition) do
      [{^partition, ^coordinator, epoch, config, count, _slots}] ->
        ratio = count / config.queue_capacity
        policy = config.pressure_policy

        level =
          cond do
            ratio >= policy[:shed_ratio] -> :shed
            ratio >= policy[:degraded_ratio] -> :degraded
            ratio >= policy[:warn_ratio] -> :warn
            true -> :normal
          end

        {:ok, epoch, Map.merge(config, %{load: count, queue_size: max(count - 1, 0), pressure_level: level})}

      _ ->
        {:error, :partition_unavailable}
    end
  rescue
    ArgumentError -> {:error, :partition_unavailable}
  end

  def reserve(instance, partition, coordinator, owner \\ self()) do
    update(instance, partition, coordinator, fn
      {partition, coordinator, epoch, config, count, slots} = row ->
        if count < config.queue_capacity do
          token = make_ref()
          next = {partition, coordinator, epoch, config, count + 1, Map.put(slots, token, {owner, :reserved})}
          {:replace, row, next, {:ok, {instance, partition, coordinator, epoch, token}}}
        else
          {:return, {:error, :queue_full}}
        end
    end)
  end

  def accept({instance, partition, coordinator, epoch, token}, owner) when coordinator == self() do
    change(instance, partition, coordinator, epoch, token, fn
      {^owner, :reserved} -> {:put, {owner, :accepted}, :ok}
      _ -> {:return, {:error, :partition_unavailable}}
    end)
  end

  def accept(_permit, _owner), do: {:error, :partition_unavailable}

  def abandon(permit), do: remove(permit, :reserved)
  def release(permit), do: remove(permit, :accepted)

  def reap(instance, partition, epoch) do
    update(instance, partition, self(), fn
      {partition, coordinator, ^epoch, config, count, slots} = row ->
        retained =
          Map.reject(slots, fn {_token, {owner, status}} -> status == :reserved and not Process.alive?(owner) end)

        if map_size(retained) == count,
          do: {:return, :ok},
          else: {:replace, row, {partition, coordinator, epoch, config, map_size(retained), retained}, :ok}

      _ ->
        {:return, :ok}
    end)
  end

  def close(instance, partition, epoch) do
    # Compare the generation so an old coordinator cannot remove its replacement.
    :ets.select_delete(table(instance), [{{partition, self(), epoch, :_, :_, :_}, [], [true]}])
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp remove({instance, partition, coordinator, epoch, token}, status) do
    change(instance, partition, coordinator, epoch, token, fn
      {_owner, ^status} -> {:delete, :ok}
      _ -> {:return, :ok}
    end)

    :ok
  end

  defp change(instance, partition, coordinator, epoch, token, action) do
    update(instance, partition, coordinator, fn
      {partition, coordinator, ^epoch, config, count, slots} = row ->
        case action.(Map.get(slots, token)) do
          {:put, value, result} ->
            {:replace, row, {partition, coordinator, epoch, config, count, Map.put(slots, token, value)}, result}

          {:delete, result} ->
            {:replace, row, {partition, coordinator, epoch, config, count - 1, Map.delete(slots, token)}, result}

          {:return, result} ->
            {:return, result}
        end

      _ ->
        {:return, {:error, :partition_unavailable}}
    end)
  end

  defp update(instance, partition, coordinator, action) do
    case :ets.lookup(table(instance), partition) do
      [{^partition, ^coordinator, _, _, _, _} = row] ->
        case action.(row) do
          {:return, result} ->
            result

          {:replace, previous, next, result} ->
            # Count and the complete token map change in one compare-and-swap.
            if :ets.select_replace(table(instance), [{previous, [], [{:const, next}]}]) == 1,
              do: result,
              else: update(instance, partition, coordinator, action)
        end

      _ ->
        {:error, :partition_unavailable}
    end
  rescue
    ArgumentError -> {:error, :partition_unavailable}
  end
end
