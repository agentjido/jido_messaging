defmodule Jido.Messaging.BoundedCall do
  @moduledoc false

  @doc false
  @spec run((-> term()), pos_integer()) :: {:ok, term()} | {:exit, term()} | :timeout
  def run(fun, timeout) when is_function(fun, 0) and is_integer(timeout) and timeout > 0 do
    owner = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    {guardian, monitor} = spawn_monitor(fn -> guard(owner, ref, fun, deadline) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guardian, reason} ->
        {:exit, reason}
    end
  end

  defp guard(owner, ref, fun, deadline) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guardian = self()

    {worker, worker_monitor} =
      :erlang.spawn_opt(fn -> send(guardian, {ref, fun.()}) end, [:link, :monitor])

    result =
      receive do
        {^ref, value} -> {:ok, value}
        {:DOWN, ^worker_monitor, :process, ^worker, reason} -> {:exit, reason}
        {:DOWN, ^owner_monitor, :process, ^owner, _} -> :owner_down
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
      end

    # The worker link also stops the callback if the guardian itself is killed.
    Process.exit(worker, :kill)
    await_down(worker_monitor, worker, result)
    Process.demonitor(owner_monitor, [:flush])
    if result != :owner_down, do: send(owner, {ref, result})
  end

  defp await_down(_monitor, _worker, {:exit, _reason}), do: :ok

  defp await_down(monitor, worker, _result) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end
end
