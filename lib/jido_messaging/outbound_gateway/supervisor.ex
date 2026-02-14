defmodule JidoMessaging.OutboundGateway.Supervisor do
  @moduledoc """
  Supervisor for outbound gateway partition workers.
  """
  use Supervisor

  alias JidoMessaging.OutboundGateway
  alias JidoMessaging.OutboundGateway.Partition

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    config = OutboundGateway.config(instance_module)
    partition_count = config[:partition_count]

    children =
      for partition <- 0..(partition_count - 1) do
        Supervisor.child_spec(
          {Partition,
           [
             instance_module: instance_module,
             partition: partition,
             queue_capacity: config[:queue_capacity],
             max_attempts: config[:max_attempts],
             base_backoff_ms: config[:base_backoff_ms],
             max_backoff_ms: config[:max_backoff_ms],
             sent_cache_size: config[:sent_cache_size]
           ]},
          id: {:outbound_gateway_partition, partition}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
