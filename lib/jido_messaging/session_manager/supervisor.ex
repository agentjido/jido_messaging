defmodule JidoMessaging.SessionManager.Supervisor do
  @moduledoc """
  Supervisor for partitioned session-routing workers.
  """
  use Supervisor

  alias JidoMessaging.SessionManager
  alias JidoMessaging.SessionManager.Partition

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    config = SessionManager.config(instance_module)
    partition_count = config[:partition_count]

    children =
      for partition <- 0..(partition_count - 1) do
        Supervisor.child_spec(
          {Partition,
           [
             instance_module: instance_module,
             partition: partition,
             ttl_ms: config[:ttl_ms],
             max_entries_per_partition: config[:max_entries_per_partition],
             prune_interval_ms: config[:prune_interval_ms]
           ]},
          id: {:session_manager_partition, partition}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
