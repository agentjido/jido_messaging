defmodule Jido.Messaging.RegistryDomain do
  @moduledoc false
  use Supervisor

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :registry), start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @doc false
  @spec start_registry(atom()) :: Supervisor.on_start()
  def start_registry(registry), do: start_registry(registry, System.monotonic_time(:millisecond) + 5_000)

  @impl true
  def init(opts) do
    workers = %{
      id: :workers,
      start: {Supervisor, :start_link, [Keyword.fetch!(opts, :children), [strategy: :one_for_one]]},
      type: :supervisor,
      shutdown: :infinity
    }

    registry = Keyword.fetch!(opts, :registry)

    registry_child = %{
      id: registry,
      start: {__MODULE__, :start_registry, [registry]},
      type: :supervisor,
      shutdown: :infinity
    }

    children = [registry_child, workers]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp start_registry(registry, deadline) do
    case Registry.start_link(keys: :unique, name: registry) do
      {:error, {:shutdown, {:failed_to_start_child, _partition, {:already_started, pid}}}} = error ->
        # A killed Registry supervisor can leave its named partition alive
        # briefly. Wait for that old child; do not exhaust restart limits while
        # its shutdown is still in progress, and do not kill an unrelated PID.
        monitor = Process.monitor(pid)
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> start_registry(registry, deadline)
        after
          remaining ->
            Process.demonitor(monitor, [:flush])
            error
        end

      result ->
        result
    end
  end
end
