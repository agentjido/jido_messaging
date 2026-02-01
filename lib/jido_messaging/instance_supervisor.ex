defmodule JidoMessaging.InstanceSupervisor do
  @moduledoc """
  Dynamic supervisor for channel instances.

  Manages the lifecycle of channel instances (e.g., Telegram bots, Discord connections).
  Each instance is its own supervisor tree containing:
  - InstanceServer (lifecycle state machine)
  - Channel-specific processes (Poller, Sender, etc.)
  """
  use DynamicSupervisor
  require Logger

  alias JidoMessaging.{Instance, InstanceServer}

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new instance.

  Returns `{:ok, instance}` with the created Instance struct, or `{:error, reason}`.
  """
  @spec start_instance(module(), atom(), map()) :: {:ok, Instance.t()} | {:error, term()}
  def start_instance(messaging_module, channel_type, attrs) do
    instance_attrs =
      attrs
      |> Map.put(:channel_type, channel_type)
      |> Map.put_new(:status, :starting)

    instance = Instance.new(instance_attrs)

    child_spec = %{
      id: {:instance, instance.id},
      start: {__MODULE__, :start_instance_tree, [messaging_module, instance]},
      restart: :temporary,
      type: :supervisor
    }

    supervisor = supervisor_name(messaging_module)

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, _pid} ->
        Logger.info("[JidoMessaging.InstanceSupervisor] Started instance #{instance.id} (#{channel_type})")
        {:ok, instance}

      {:error, reason} = error ->
        Logger.error("[JidoMessaging.InstanceSupervisor] Failed to start instance: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Start the instance supervision tree (called by DynamicSupervisor).
  """
  def start_instance_tree(messaging_module, instance) do
    children = [
      {InstanceServer, instance_module: messaging_module, instance: instance}
      # Channel-specific children will be added based on channel_type
      # e.g., Telegram.Poller, Telegram.Sender
    ]

    opts = [
      strategy: :one_for_one,
      name: instance_supervisor_name(messaging_module, instance.id)
    ]

    Supervisor.start_link(children, opts)
  end

  @doc """
  Stop an instance by ID.
  """
  @spec stop_instance(module(), String.t()) :: :ok | {:error, :not_found}
  def stop_instance(messaging_module, instance_id) do
    case InstanceServer.whereis(messaging_module, instance_id) do
      nil ->
        {:error, :not_found}

      pid ->
        InstanceServer.stop(pid)

        supervisor = supervisor_name(messaging_module)
        instance_sup = instance_supervisor_name(messaging_module, instance_id)

        case Process.whereis(instance_sup) do
          nil -> :ok
          sup_pid -> DynamicSupervisor.terminate_child(supervisor, sup_pid)
        end

        Logger.info("[JidoMessaging.InstanceSupervisor] Stopped instance #{instance_id}")
        :ok
    end
  end

  @doc """
  Get the status of an instance.
  """
  @spec instance_status(module(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def instance_status(messaging_module, instance_id) do
    InstanceServer.status({messaging_module, instance_id})
  end

  @doc """
  List all running instances.
  """
  @spec list_instances(module()) :: [map()]
  def list_instances(messaging_module) do
    registry = Module.concat(messaging_module, Registry.Instances)

    Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn
      {{:instance, _id}, _pid} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:instance, id}, pid} ->
      case InstanceServer.status(pid) do
        {:ok, status} -> status
        _ -> %{instance_id: id, status: :unknown}
      end
    end)
  end

  @doc """
  Count running instances.
  """
  @spec count_instances(module()) :: non_neg_integer()
  def count_instances(messaging_module) do
    supervisor = supervisor_name(messaging_module)

    case Process.whereis(supervisor) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(supervisor).active
    end
  end

  @doc """
  Get health snapshots for all running instances.

  Returns a list of health snapshot maps for each instance.
  """
  @spec list_instance_health(module()) :: [map()]
  def list_instance_health(messaging_module) do
    registry = Module.concat(messaging_module, Registry.Instances)

    Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn
      {{:instance, _id}, _pid} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:instance, _id}, pid} ->
      {:ok, snapshot} = InstanceServer.health_snapshot(pid)
      snapshot
    end)
  end

  defp supervisor_name(messaging_module) do
    Module.concat(messaging_module, InstanceSupervisor)
  end

  defp instance_supervisor_name(messaging_module, instance_id) do
    Module.concat([messaging_module, Instance, instance_id])
  end
end
