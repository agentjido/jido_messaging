defmodule Jido.Messaging.Supervisor do
  @moduledoc """
  Main supervisor for a Jido.Messaging instance.

  Started by the host application's messaging module (defined with `use Jido.Messaging`).
  Each instance has its own isolated supervision tree.
  """
  use Supervisor

  alias Jido.Messaging.BridgeRegistry

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    # Ensure Jido.Messaging signal extensions are registered
    Jido.Messaging.Signal.Ext.CorrelationId.ensure_registered()

    instance_module = Keyword.fetch!(opts, :instance_module)
    persistence = Keyword.fetch!(opts, :persistence)
    persistence_opts = Keyword.get(opts, :persistence_opts, [])
    runtime_profile = Keyword.get(opts, :runtime_profile, :full)
    runtime_features = resolve_runtime_features(runtime_profile, Keyword.get(opts, :runtime_features, []))
    bridge_manifest_paths = Keyword.get(opts, :bridge_manifest_paths, [])
    required_bridges = Keyword.get(opts, :required_bridges, [])
    bridge_collision_policy = Keyword.get(opts, :bridge_collision_policy, :prefer_last)

    case BridgeRegistry.bootstrap_from_manifests(
           manifest_paths: bridge_manifest_paths,
           required_bridges: required_bridges,
           collision_policy: bridge_collision_policy
         ) do
      {:ok, _bootstrap_result} ->
        runtime_name = Module.concat(instance_module, Runtime)
        room_registry_name = Module.concat(instance_module, Registry.Rooms)
        room_supervisor_name = Module.concat(instance_module, RoomSupervisor)
        agent_registry_name = Module.concat(instance_module, Registry.Agents)
        agent_supervisor_name = Module.concat(instance_module, AgentSupervisor)
        instance_registry_name = Module.concat(instance_module, Registry.Instances)
        bridge_registry_name = Module.concat(instance_module, Registry.Bridges)
        instance_supervisor_name = Module.concat(instance_module, InstanceSupervisor)
        bridge_supervisor_name = Module.concat(instance_module, BridgeSupervisor)
        onboarding_registry_name = Module.concat(instance_module, Registry.Onboarding)
        onboarding_supervisor_name = Module.concat(instance_module, OnboardingSupervisor)
        session_manager_supervisor_name = Module.concat(instance_module, SessionManagerSupervisor)
        dead_letter_name = Module.concat(instance_module, DeadLetter)
        dead_letter_replay_supervisor_name = Module.concat(instance_module, DeadLetterReplaySupervisor)
        outbound_gateway_supervisor_name = Module.concat(instance_module, OutboundGatewaySupervisor)
        config_store_name = Module.concat(instance_module, ConfigStore)
        deduper_name = Module.concat(instance_module, Deduper)
        signal_bus_name = Module.concat(instance_module, SignalBus)

        base_children = [
          {Registry, keys: :unique, name: room_registry_name},
          {Registry, keys: :unique, name: agent_registry_name},
          {Registry, keys: :unique, name: instance_registry_name},
          {Registry, keys: :unique, name: bridge_registry_name},
          {Jido.Signal.Bus, name: signal_bus_name},
          {Jido.Messaging.RoomSupervisor, name: room_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.AgentSupervisor, name: agent_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.SessionManager.Supervisor,
           name: session_manager_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.DeadLetter, name: dead_letter_name, instance_module: instance_module},
          {Jido.Messaging.DeadLetter.ReplaySupervisor,
           name: dead_letter_replay_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.OutboundGateway.Supervisor,
           name: outbound_gateway_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.ConfigStore, name: config_store_name, instance_module: instance_module},
          {Jido.Messaging.InstanceSupervisor, name: instance_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.BridgeSupervisor, name: bridge_supervisor_name, instance_module: instance_module},
          {Jido.Messaging.Deduper, name: deduper_name, instance_module: instance_module},
          {Jido.Messaging.Runtime,
           name: runtime_name,
           instance_module: instance_module,
           persistence: persistence,
           persistence_opts: persistence_opts}
        ]

        onboarding_children =
          if :onboarding in runtime_features do
            [
              {Registry, keys: :unique, name: onboarding_registry_name},
              {Jido.Messaging.Onboarding.Supervisor, name: onboarding_supervisor_name, instance_module: instance_module}
            ]
          else
            []
          end

        children = base_children ++ onboarding_children

        Supervisor.init(children, strategy: :one_for_one)

      {:error, {:fatal_required_bridge_error, diagnostic}} ->
        {:stop, {:fatal_required_bridge_error, diagnostic}}
    end
  end

  defp resolve_runtime_features(profile, explicit_features) do
    core = [:core_runtime]

    profile_features =
      case profile do
        :core -> core
        :full -> core ++ [:onboarding]
        _ -> core ++ [:onboarding]
      end

    (profile_features ++ explicit_features)
    |> Enum.uniq()
  end

  @doc """
  Returns the Signal Bus name for a given messaging module.
  """
  @spec signal_bus_name(module()) :: atom()
  def signal_bus_name(instance_module) do
    Module.concat(instance_module, SignalBus)
  end
end
