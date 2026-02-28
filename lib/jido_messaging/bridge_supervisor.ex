defmodule Jido.Messaging.BridgeSupervisor do
  @moduledoc """
  Dynamic supervisor for bridge runtime workers.

  Bridge workers are reconciled against `ConfigStore` bridge configs.
  """

  use DynamicSupervisor

  alias Jido.Messaging.{BridgeServer, ConfigStore}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec reconcile(module()) :: :ok | {:error, term()}
  def reconcile(instance_module) when is_atom(instance_module) do
    desired =
      ConfigStore.list_bridge_configs(instance_module, enabled: true)
      |> Map.new(fn config -> {config.id, config} end)

    running = Map.new(list_running(instance_module), fn {bridge_id, pid} -> {bridge_id, pid} end)

    running
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(desired, &1))
    |> Enum.each(&stop_bridge(instance_module, &1))

    Enum.each(desired, fn {bridge_id, config} ->
      case Map.get(running, bridge_id) do
        nil ->
          _ = start_bridge(instance_module, config)

        pid ->
          case BridgeServer.status(pid) do
            {:ok, %{revision: revision, adapter_module: adapter_module}} ->
              if revision != config.revision or adapter_module != config.adapter_module do
                _ = stop_bridge(instance_module, bridge_id)
                _ = start_bridge(instance_module, config)
              end

            _ ->
              _ = stop_bridge(instance_module, bridge_id)
              _ = start_bridge(instance_module, config)
          end
      end
    end)

    :ok
  end

  @spec start_bridge(module(), Jido.Messaging.BridgeConfig.t()) :: {:ok, pid()} | {:error, term()}
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
  def stop_bridge(instance_module, bridge_id) when is_binary(bridge_id) do
    case BridgeServer.whereis(instance_module, bridge_id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(supervisor_name(instance_module), pid)
    end
  end

  @spec list_bridges(module()) :: [map()]
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

  defp supervisor_name(instance_module), do: Module.concat(instance_module, BridgeSupervisor)
end
