defmodule Jido.Messaging.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor for spawning and managing AgentRunner processes.

  Each Jido.Messaging instance has its own AgentSupervisor that manages
  agent runners on-demand.
  """
  use DynamicSupervisor

  alias Jido.Messaging.{AgentRunner, DesiredWorkers}

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, _pid} = ok ->
        DesiredWorkers.restore(name)
        instance = Keyword.get(opts, :instance_module)
        unless DesiredWorkers.managed?(instance), do: maybe_restore_assigned_runners(instance)
        ok

      other ->
        other
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an agent assigned to a room thread.

  Returns `{:ok, pid}` if started successfully, or `{:error, {:already_started, pid}}`
  if the agent is already running in this room.

  ## Options

  The `agent_config` map must include:
  - `:handler` - Function `(message, context) -> {:reply, text} | :noreply | {:error, reason}`
  - `:trigger` - `:all` | `:mention` | `{:prefix, "/cmd"}`
  - `:name` - Display name for the agent
  """
  def start_agent(instance_module, room_id, thread_id, agent_id, agent_config) do
    supervisor = Module.concat(instance_module, AgentSupervisor)

    child_spec = {
      AgentRunner,
      [
        room_id: room_id,
        thread_id: thread_id,
        agent_id: agent_id,
        agent_config: agent_config,
        instance_module: instance_module
      ]
    }

    try do
      case DesiredWorkers.start(instance_module, supervisor, {room_id, thread_id, agent_id}, child_spec) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          if owned_runner?(supervisor, pid) do
            {:ok, pid}
          else
            await_stale_runner(instance_module, room_id, thread_id, agent_id, agent_config, pid)
          end

        {:error, :already_present} ->
          case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
            pid when is_pid(pid) -> {:ok, pid}
            nil -> {:error, :runner_unavailable}
          end

        {:error, :supervisor_unavailable} ->
          {:error, {:supervisor_unavailable, :noproc}}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason ->
        {:error, {:supervisor_unavailable, reason}}
    end
  end

  @doc """
  Stop an agent assigned to a room thread.

  Returns `:ok` if stopped, or `{:error, :not_found}` if not running.
  """
  def stop_agent(instance_module, room_id, thread_id, agent_id) do
    case AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) do
      nil ->
        stop_owned_runner(instance_module, room_id, thread_id, agent_id)

      pid ->
        ref = Process.monitor(pid)

        try do
          case stop_owned_runner(instance_module, room_id, thread_id, agent_id) do
            :ok ->
              await_agent_stop(pid, ref)

            {:error, _reason} = error ->
              Process.demonitor(ref, [:flush])
              error
          end
        catch
          :exit, reason ->
            Process.demonitor(ref, [:flush])
            {:error, {:supervisor_unavailable, reason}}
        end
    end
  end

  @doc """
  List all running agents in a room.

  Returns a list of `{{thread_id, agent_id}, pid}` tuples.
  """
  def list_agents(instance_module, room_id) do
    list_all_agents(instance_module)
    |> Enum.flat_map(fn
      {^room_id, thread_id, agent_id, pid} -> [{{thread_id, agent_id}, pid}]
      {_other_room_id, _thread_id, _agent_id, _pid} -> []
    end)
  end

  @doc "Count running agent runners for this instance"
  def count_agents(instance_module) do
    supervisor = Module.concat(instance_module, AgentSupervisor)
    DynamicSupervisor.count_children(supervisor).active
  catch
    :exit, _reason -> 0
  end

  @doc "List all running agents across all rooms"
  def list_all_agents(instance_module) do
    supervisor = Module.concat(instance_module, AgentSupervisor)
    registry = Module.concat(instance_module, Registry.Agents)

    DynamicSupervisor.which_children(supervisor)
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(registry, pid) do
        [{room_id, thread_id, agent_id}] -> {room_id, thread_id, agent_id, pid}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  rescue
    ArgumentError -> []
  catch
    :exit, _reason -> []
  end

  defp stop_owned_runner(instance_module, room_id, thread_id, agent_id) do
    supervisor = Module.concat(instance_module, AgentSupervisor)
    lookup = fn -> AgentRunner.whereis(instance_module, room_id, thread_id, agent_id) end

    case DesiredWorkers.stop(instance_module, supervisor, {room_id, thread_id, agent_id}, lookup) do
      {:error, :supervisor_unavailable} -> {:error, {:supervisor_unavailable, :noproc}}
      result -> result
    end
  end

  defp await_agent_stop(pid, ref, timeout_ms \\ 1_000) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])

        if Process.alive?(pid) do
          {:error, :stop_timeout}
        else
          :ok
        end
    end
  end

  defp owned_runner?(supervisor, pid) do
    Enum.any?(DynamicSupervisor.which_children(supervisor), fn {_, child, _, _} -> child == pid end)
  end

  defp await_stale_runner(instance_module, room_id, thread_id, agent_id, agent_config, pid) do
    ref = Process.monitor(pid)

    :telemetry.execute([:jido_messaging, :agent, :stale_runner], %{}, %{
      instance_module: instance_module,
      room_id: room_id,
      thread_id: thread_id,
      agent_id: agent_id,
      pid: pid
    })

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        start_agent(instance_module, room_id, thread_id, agent_id, agent_config)
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :stale_runner_timeout}
    end
  end

  defp maybe_restore_assigned_runners(instance_module) when is_atom(instance_module) do
    Task.start(fn -> retry_restore_assigned_runners(instance_module, 5) end)
    :ok
  end

  defp retry_restore_assigned_runners(_instance_module, 0), do: :ok

  defp retry_restore_assigned_runners(instance_module, attempts_left) do
    case Jido.Messaging.restore_agent_runners(instance_module) do
      :ok ->
        :ok

      {:error, :runtime_unavailable} ->
        Process.sleep(50)
        retry_restore_assigned_runners(instance_module, attempts_left - 1)

      {:error, _reason} ->
        :ok
    end
  end
end
