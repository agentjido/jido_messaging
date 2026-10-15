defmodule Jido.Messaging.SubscriptionSupervisor do
  @moduledoc false
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    instance = Keyword.fetch!(opts, :instance_module)

    children = [
      {Registry, keys: :unique, name: Module.concat(instance, Registry.Subscriptions)},
      {DynamicSupervisor, name: Module.concat(instance, SubscriptionWorkers), strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
