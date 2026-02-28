defmodule Jido.Messaging.InstanceSupervisor do
  @moduledoc """
  Dynamic supervisor for channel instances.

  Manages the lifecycle of channel instances (e.g., Telegram bots, Discord connections).
  Each instance is its own supervisor tree containing:
  - InstanceServer (lifecycle state machine)
  - Channel-specific processes (Poller, Sender, etc.)
  """
  use DynamicSupervisor
  require Logger

  alias Jido.Messaging.{Instance, InstanceReconnectWorker, InstanceServer, BridgeRegistry}

  @instance_domain_max_restarts 6
  @instance_domain_max_seconds 30
  @instance_subtree_max_restarts 5
  @instance_subtree_max_seconds 30

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: @instance_domain_max_restarts,
      max_seconds: @instance_domain_max_seconds
    )
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
      restart: :permanent,
      type: :supervisor
    }

    supervisor = supervisor_name(messaging_module)

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, _pid} ->
        Logger.info("[Jido.Messaging.InstanceSupervisor] Started instance #{instance.id} (#{channel_type})")
        {:ok, instance}

      {:error, reason} = error ->
        Logger.error("[Jido.Messaging.InstanceSupervisor] Failed to start instance: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Start the instance supervision tree (called by DynamicSupervisor).
  """
  def start_instance_tree(messaging_module, instance) do
    channel_module = resolve_channel_module(instance)

    instance_server_spec = {InstanceServer, instance_module: messaging_module, instance: instance}

    reconnect_worker_spec =
      Supervisor.child_spec(
        {InstanceReconnectWorker,
         [
           instance_module: messaging_module,
           instance: instance,
           channel_module: channel_module,
           instance_server: instance_server_name(messaging_module, instance.id)
         ]},
        id: {:instance_reconnect_worker, instance.id}
      )

    children = [instance_server_spec, reconnect_worker_spec]

    opts = [
      strategy: :one_for_one,
      max_restarts: @instance_subtree_max_restarts,
      max_seconds: @instance_subtree_max_seconds,
      name: instance_supervisor_name(messaging_module, instance.id)
    ]

    Supervisor.start_link(children, opts)
  end

  @doc """
  Stop an instance by ID.
  """
  @spec stop_instance(module(), String.t()) :: :ok | {:error, :not_found}
  def stop_instance(messaging_module, instance_id) do
    supervisor = supervisor_name(messaging_module)
    instance_sup = instance_supervisor_name(messaging_module, instance_id)

    case Process.whereis(instance_sup) do
      nil ->
        {:error, :not_found}

      sup_pid ->
        case DynamicSupervisor.terminate_child(supervisor, sup_pid) do
          :ok ->
            Logger.info("[Jido.Messaging.InstanceSupervisor] Stopped instance #{instance_id}")
            :ok

          {:error, :not_found} ->
            {:error, :not_found}
        end
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

  defp instance_server_name(messaging_module, instance_id) do
    {:via, Registry, {Module.concat(messaging_module, Registry.Instances), {:instance, instance_id}}}
  end

  defp resolve_channel_module(instance) do
    settings = normalize_settings(instance.settings)

    custom_module =
      Map.get(settings, :adapter_module) || Map.get(settings, "adapter_module") ||
        Map.get(settings, :channel_module) || Map.get(settings, "channel_module")

    cond do
      is_atom(custom_module) and Code.ensure_loaded?(custom_module) ->
        custom_module

      bridge_module = BridgeRegistry.get_adapter_module(instance.channel_type) ->
        bridge_module

      true ->
        nil
    end
  end

  defp normalize_settings(settings) when is_map(settings), do: settings
  defp normalize_settings(_), do: %{}
end
