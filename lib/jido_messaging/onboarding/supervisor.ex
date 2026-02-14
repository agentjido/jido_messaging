defmodule JidoMessaging.Onboarding.Supervisor do
  @moduledoc """
  Dynamic supervisor for onboarding workers partitioned by onboarding ID.
  """
  use DynamicSupervisor

  alias JidoMessaging.Onboarding.Worker

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_worker(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_worker(instance_module, onboarding_id, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_list(opts) do
    supervisor = supervisor_name(instance_module)

    child_spec =
      {Worker,
       [
         instance_module: instance_module,
         onboarding_id: onboarding_id,
         start_request: Keyword.get(opts, :start_request)
       ]}

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> {:ok, Worker.whereis(instance_module, onboarding_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_or_start_worker(module(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_start_worker(instance_module, onboarding_id, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_list(opts) do
    case Worker.whereis(instance_module, onboarding_id) do
      nil -> start_worker(instance_module, onboarding_id, opts)
      pid -> {:ok, pid}
    end
  end

  @spec count_workers(module()) :: non_neg_integer()
  def count_workers(instance_module) when is_atom(instance_module) do
    instance_module
    |> supervisor_name()
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end

  @spec supervisor_name(module()) :: atom()
  def supervisor_name(instance_module), do: Module.concat(instance_module, OnboardingSupervisor)
end
