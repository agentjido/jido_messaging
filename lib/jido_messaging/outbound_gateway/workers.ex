defmodule Jido.Messaging.OutboundGateway.Workers do
  @moduledoc false
  alias Jido.Messaging.Runtime

  def start_link(instance, partition) do
    table = Runtime.request_table(instance.__jido_messaging__(:runtime))
    key = {:outbound_workers, partition}
    # Runtime survives a partition or Registry replacement. Stop the old worker
    # group before a new coordinator can start provider work.
    case :ets.take(table, key) do
      [{^key, previous}] -> stop(previous)
      [] -> :ok
    end

    with {:ok, supervisor} <- Task.Supervisor.start_link() do
      :ets.insert(table, {key, supervisor})
      {:ok, supervisor}
    end
  end

  def stop(supervisor) do
    monitor = Process.monitor(supervisor)

    try do
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :shutdown, :infinity)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^supervisor, _reason} -> :ok
    end
  end
end
