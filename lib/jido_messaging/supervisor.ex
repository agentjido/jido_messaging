defmodule JidoMessaging.Supervisor do
  @moduledoc """
  Main supervisor for a JidoMessaging instance.

  Started by the host application's messaging module (defined with `use JidoMessaging`).
  Each instance has its own isolated supervision tree.
  """
  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # Ensure JidoMessaging signal extensions are registered
    JidoMessaging.Signal.Ext.CorrelationId.ensure_registered()

    instance_module = Keyword.fetch!(opts, :instance_module)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    runtime_name = Module.concat(instance_module, Runtime)
    room_registry_name = Module.concat(instance_module, Registry.Rooms)
    room_supervisor_name = Module.concat(instance_module, RoomSupervisor)
    agent_registry_name = Module.concat(instance_module, Registry.Agents)
    agent_supervisor_name = Module.concat(instance_module, AgentSupervisor)
    instance_registry_name = Module.concat(instance_module, Registry.Instances)
    instance_supervisor_name = Module.concat(instance_module, InstanceSupervisor)
    onboarding_registry_name = Module.concat(instance_module, Registry.Onboarding)
    onboarding_supervisor_name = Module.concat(instance_module, OnboardingSupervisor)
    session_manager_supervisor_name = Module.concat(instance_module, SessionManagerSupervisor)
    outbound_gateway_supervisor_name = Module.concat(instance_module, OutboundGatewaySupervisor)
    deduper_name = Module.concat(instance_module, Deduper)
    signal_bus_name = Module.concat(instance_module, SignalBus)

    children = [
      {Registry, keys: :unique, name: room_registry_name},
      {Registry, keys: :unique, name: agent_registry_name},
      {Registry, keys: :unique, name: instance_registry_name},
      {Registry, keys: :unique, name: onboarding_registry_name},
      {Jido.Signal.Bus, name: signal_bus_name},
      {JidoMessaging.RoomSupervisor, name: room_supervisor_name, instance_module: instance_module},
      {JidoMessaging.AgentSupervisor, name: agent_supervisor_name, instance_module: instance_module},
      {JidoMessaging.Onboarding.Supervisor, name: onboarding_supervisor_name, instance_module: instance_module},
      {JidoMessaging.SessionManager.Supervisor,
       name: session_manager_supervisor_name, instance_module: instance_module},
      {JidoMessaging.OutboundGateway.Supervisor,
       name: outbound_gateway_supervisor_name, instance_module: instance_module},
      {JidoMessaging.InstanceSupervisor, name: instance_supervisor_name, instance_module: instance_module},
      {JidoMessaging.Deduper, name: deduper_name, instance_module: instance_module},
      {JidoMessaging.Runtime,
       name: runtime_name, instance_module: instance_module, adapter: adapter, adapter_opts: adapter_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the Signal Bus name for a given messaging module.
  """
  @spec signal_bus_name(module()) :: atom()
  def signal_bus_name(instance_module) do
    Module.concat(instance_module, SignalBus)
  end
end
