defmodule Jido.Messaging.DeadLetter.ReplaySupervisor do
  @moduledoc """
  Supervisor for partitioned dead-letter replay workers.
  """
  use Supervisor

  alias Jido.Messaging.DeadLetter
  alias Jido.Messaging.DeadLetter.ReplayWorker

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    replay_partitions = DeadLetter.config(instance_module)[:replay_partitions]
    registry_name = DeadLetter.replay_registry_name(instance_module)

    worker_children =
      for partition <- 0..(replay_partitions - 1) do
        Supervisor.child_spec(
          {ReplayWorker, [instance_module: instance_module, partition: partition]},
          id: {:dead_letter_replay_worker, partition}
        )
      end

    children = [{Registry, keys: :unique, name: registry_name} | worker_children]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
