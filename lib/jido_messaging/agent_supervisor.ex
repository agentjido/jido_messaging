defmodule Jido.Messaging.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for spawning and managing AgentRunner processes.

  Each Jido.Messaging instance has its own AgentSupervisor that manages
  agent runners on-demand.
  """
  use DynamicSupervisor

  alias Jido.Messaging.AgentRunner

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an agent in a room.

  Returns `{:ok, pid}` if started successfully, or `{:error, {:already_started, pid}}`
  if the agent is already running in this room.

  ## Options

  The `agent_config` map must include:
  - `:handler` - Function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:trigger` - `:all` | `:mention` | `{:prefix, "/cmd"}`
  - `:name` - Display name for the agent
  """
  def start_agent(instance_module, room_id, agent_id, agent_config) do
    supervisor = Module.concat(instance_module, AgentSupervisor)

    child_spec = {
      AgentRunner,
      room_id: room_id, agent_id: agent_id, agent_config: agent_config, instance_module: instance_module
    }

    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Stop an agent in a room.

  Returns `:ok` if stopped, or `{:error, :not_found}` if not running.
  """
  def stop_agent(instance_module, room_id, agent_id) do
    case AgentRunner.whereis(instance_module, room_id, agent_id) do
      nil ->
        {:error, :not_found}

      pid ->
        supervisor = Module.concat(instance_module, AgentSupervisor)
        DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @doc """
  List all agents in a room.

  Returns a list of `{agent_id, pid}` tuples.
  """
  def list_agents(instance_module, room_id) do
    registry = Module.concat(instance_module, Registry.Agents)

    Registry.select(registry, [
      {{{:"$1", :"$2"}, :"$3", :_}, [{:==, :"$1", room_id}], [{{:"$2", :"$3"}}]}
    ])
  end

  @doc "Count running agent runners for this instance"
  def count_agents(instance_module) do
    supervisor = Module.concat(instance_module, AgentSupervisor)
    DynamicSupervisor.count_children(supervisor).active
  end

  @doc "List all running agents across all rooms"
  def list_all_agents(instance_module) do
    supervisor = Module.concat(instance_module, AgentSupervisor)
    registry = Module.concat(instance_module, Registry.Agents)

    DynamicSupervisor.which_children(supervisor)
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(registry, pid) do
        [{room_id, agent_id}] -> {room_id, agent_id, pid}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
