defmodule Jido.Messaging.BridgeServer do
  @moduledoc """
  Runtime bridge process for a single configured bridge.

  Holds resolved bridge config and owns adapter listener child specs.
  """

  use GenServer

  alias Jido.Messaging.{AdapterBridge, BridgeConfig}

  @type state :: %{
          instance_module: module(),
          bridge_id: String.t(),
          config: BridgeConfig.t(),
          listener_supervisor: pid() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    registry = Module.concat(instance_module, Registry.Bridges)
    name = {:via, Registry, {registry, {:bridge, bridge_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec whereis(module(), String.t()) :: pid() | nil
  def whereis(instance_module, bridge_id) do
    registry = Module.concat(instance_module, Registry.Bridges)

    case Registry.lookup(registry, {:bridge, bridge_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec status(pid()) :: {:ok, map()}
  def status(pid) when is_pid(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    config = Keyword.fetch!(opts, :config)

    with {:ok, listener_specs} <- resolve_listener_specs(instance_module, bridge_id, config),
         {:ok, listener_supervisor} <- start_listener_supervisor(listener_specs) do
      {:ok,
       %{
         instance_module: instance_module,
         bridge_id: bridge_id,
         config: config,
         listener_supervisor: listener_supervisor
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    listener_count =
      case state.listener_supervisor do
        nil -> 0
        pid -> Supervisor.count_children(pid).active
      end

    {:reply,
     {:ok,
      %{
        bridge_id: state.bridge_id,
        adapter_module: state.config.adapter_module,
        enabled: state.config.enabled,
        revision: state.config.revision,
        listener_count: listener_count
      }}, state}
  end

  defp resolve_listener_specs(instance_module, bridge_id, %BridgeConfig{} = config) do
    opts = [
      instance_module: instance_module,
      bridge_id: bridge_id,
      bridge_config: config,
      settings: config.opts || %{}
    ]

    AdapterBridge.listener_child_specs(config.adapter_module, bridge_id, opts)
  end

  defp start_listener_supervisor([]), do: {:ok, nil}

  defp start_listener_supervisor(listener_specs) when is_list(listener_specs) do
    Supervisor.start_link(listener_specs, strategy: :one_for_one)
  end
end
