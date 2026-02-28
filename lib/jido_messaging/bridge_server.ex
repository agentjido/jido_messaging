defmodule Jido.Messaging.BridgeServer do
  @moduledoc """
  Runtime bridge process for a single configured bridge.

  Holds resolved bridge config and owns adapter listener child specs.
  """

  use GenServer

  alias Jido.Messaging.{AdapterBridge, BridgeConfig, BridgeStatus}

  @type state :: %{
          instance_module: module(),
          bridge_id: String.t(),
          config: BridgeConfig.t(),
          listener_supervisor: pid() | nil,
          last_ingress_at: DateTime.t() | nil,
          last_outbound_at: DateTime.t() | nil,
          last_error: term() | nil
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

  @spec status(pid()) :: {:ok, BridgeStatus.t()}
  def status(pid) when is_pid(pid), do: GenServer.call(pid, :status)

  @spec mark_ingress(module(), String.t()) :: :ok
  def mark_ingress(instance_module, bridge_id) when is_atom(instance_module) and is_binary(bridge_id) do
    case whereis(instance_module, bridge_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :mark_ingress)
    end
  end

  @spec mark_outbound(module(), String.t()) :: :ok
  def mark_outbound(instance_module, bridge_id) when is_atom(instance_module) and is_binary(bridge_id) do
    case whereis(instance_module, bridge_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :mark_outbound)
    end
  end

  @spec mark_error(module(), String.t(), term()) :: :ok
  def mark_error(instance_module, bridge_id, reason) when is_atom(instance_module) and is_binary(bridge_id) do
    case whereis(instance_module, bridge_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:mark_error, reason})
    end
  end

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
         listener_supervisor: listener_supervisor,
         last_ingress_at: nil,
         last_outbound_at: nil,
         last_error: nil
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

    status =
      BridgeStatus.new(%{
        bridge_id: state.bridge_id,
        adapter_module: state.config.adapter_module,
        enabled: state.config.enabled,
        revision: state.config.revision,
        listener_count: listener_count,
        last_ingress_at: state.last_ingress_at,
        last_outbound_at: state.last_outbound_at,
        last_error: state.last_error
      })

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_cast(:mark_ingress, state) do
    {:noreply, %{state | last_ingress_at: DateTime.utc_now()}}
  end

  def handle_cast(:mark_outbound, state) do
    {:noreply, %{state | last_outbound_at: DateTime.utc_now()}}
  end

  def handle_cast({:mark_error, reason}, state) do
    {:noreply, %{state | last_error: reason}}
  end

  defp resolve_listener_specs(instance_module, bridge_id, %BridgeConfig{} = config) do
    settings = config.opts || %{}
    ingress = ingress_settings(settings)

    opts = [
      instance_module: instance_module,
      bridge_id: bridge_id,
      bridge_config: config,
      settings: settings,
      ingress: ingress,
      sink_mfa: {Jido.Messaging.IngressSink, :emit, [instance_module, bridge_id]}
    ]

    AdapterBridge.listener_child_specs(config.adapter_module, bridge_id, opts)
  end

  defp start_listener_supervisor([]), do: {:ok, nil}

  defp start_listener_supervisor(listener_specs) when is_list(listener_specs) do
    Supervisor.start_link(listener_specs, strategy: :one_for_one)
  end

  defp ingress_settings(settings) when is_map(settings) do
    Map.get(settings, :ingress) || Map.get(settings, "ingress") || %{}
  end
end
