defmodule Jido.Messaging.BridgeSupervisor do
  @moduledoc """
  Dynamic supervisor for bridge runtime workers.

  Bridge workers are reconciled against `ConfigStore` bridge configs.
  """

  use DynamicSupervisor

  alias Jido.Messaging.{BridgeServer, ConfigStore}

  @spec start_link(keyword()) :: Supervisor.on_start()
  @doc """
  Starts the dynamic supervisor that owns bridge runtime workers.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    instance_module = Keyword.fetch!(opts, :instance_module)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, supervisor} ->
        case reconcile(instance_module) do
          :ok ->
            {:ok, supervisor}

          {:error, _reason} = error ->
            :ok = Supervisor.stop(supervisor)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec reconcile(module()) :: :ok | {:error, term()}
  @doc """
  Reconciles running bridge workers against enabled bridge configs.
  """
  def reconcile(instance_module) when is_atom(instance_module) do
    desired =
      ConfigStore.list_bridge_configs(instance_module, enabled: true)
      |> Map.new(fn config -> {config.id, config} end)

    running = Map.new(list_running(instance_module), fn {bridge_id, pid} -> {bridge_id, pid} end)

    with :ok <- stop_removed_bridges(instance_module, desired, running),
         :ok <- reconcile_desired_bridges(instance_module, desired, running) do
      :ok
    end
  end

  @spec start_bridge(module(), Jido.Messaging.BridgeConfig.t()) :: {:ok, pid()} | {:error, term()}
  @doc """
  Starts a bridge worker for a resolved bridge config.
  """
  def start_bridge(instance_module, config) do
    child_spec = %{
      id: {:bridge, config.id},
      start: {BridgeServer, :start_link, [[instance_module: instance_module, bridge_id: config.id, config: config]]},
      restart: :permanent,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor_name(instance_module), child_spec)
  end

  @spec stop_bridge(module(), String.t()) :: :ok | {:error, :not_found | term()}
  @doc """
  Stops the running bridge worker for `bridge_id`.
  """
  def stop_bridge(instance_module, bridge_id) when is_binary(bridge_id) do
    case BridgeServer.whereis(instance_module, bridge_id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(supervisor_name(instance_module), pid)
    end
  end

  @spec list_bridges(module()) :: [Jido.Messaging.BridgeStatus.t()]
  @doc """
  Lists status snapshots for all running bridges.
  """
  def list_bridges(instance_module) when is_atom(instance_module) do
    list_running(instance_module)
    |> Enum.map(fn {_bridge_id, pid} ->
      {:ok, status} = BridgeServer.status(pid)
      status
    end)
    |> Enum.sort_by(& &1.bridge_id)
  end

  defp list_running(instance_module) do
    registry = Module.concat(instance_module, Registry.Bridges)

    Registry.select(registry, [{{{:bridge, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
  end

  defp stop_removed_bridges(instance_module, desired, running) do
    running
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(desired, &1))
    |> Enum.reduce_while(:ok, fn bridge_id, :ok ->
      case stop_bridge(instance_module, bridge_id) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
      end
    end)
  end

  defp reconcile_desired_bridges(instance_module, desired, running) do
    Enum.reduce_while(desired, :ok, fn {bridge_id, config}, :ok ->
      case reconcile_bridge(instance_module, config, Map.get(running, bridge_id)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:reconcile_bridge_failed, bridge_id, reason}}}
      end
    end)
  end

  defp reconcile_bridge(instance_module, config, nil) do
    case start_bridge(instance_module, config) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp reconcile_bridge(instance_module, config, pid) do
    with {:ok, status} <- BridgeServer.status(pid) do
      if status.revision == config.revision and status.adapter_module == config.adapter_module do
        :ok
      else
        with :ok <- stop_bridge(instance_module, config.id),
             {:ok, _pid} <- start_bridge(instance_module, config) do
          :ok
        end
      end
    end
  end

  defp supervisor_name(instance_module), do: Module.concat(instance_module, BridgeSupervisor)
end
