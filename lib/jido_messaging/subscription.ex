defmodule Jido.Messaging.Subscription do
  @moduledoc false
  use GenServer, restart: :transient

  alias Jido.Signal.Bus

  @spec ensure(module(), pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure(instance, consumer, path, selector) do
    id = :crypto.hash(:sha256, :erlang.term_to_binary({instance, consumer, path, selector}))

    opts = [
      instance: instance,
      consumer: consumer,
      path: path,
      selector: selector,
      subscription_id: "messaging:" <> Base.url_encode64(id, padding: false)
    ]

    case DynamicSupervisor.start_child(Module.concat(instance, SubscriptionWorkers), {__MODULE__, opts}) do
      {:error, {:already_started, worker}} -> {:ok, worker}
      result -> result
    end
  catch
    :exit, _ -> {:error, :subscription_unavailable}
  end

  @spec current?(module(), pid(), pid()) :: boolean()
  def current?(instance, consumer, worker) do
    Registry.lookup(Module.concat(instance, Registry.Subscriptions), consumer) == [{worker, nil}]
  rescue
    ArgumentError -> false
  end

  @spec monitor(pid()) :: reference()
  def monitor(worker), do: :erlang.monitor(:process, worker, [{:tag, :messaging_subscription_down}])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry = Module.concat(Keyword.fetch!(opts, :instance), Registry.Subscriptions)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, Keyword.fetch!(opts, :consumer)}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    consumer = Keyword.fetch!(opts, :consumer)

    state = %{
      consumer: consumer,
      consumer_monitor: Process.monitor(consumer),
      bus_name: Jido.Messaging.Supervisor.signal_bus_name(Keyword.fetch!(opts, :instance)),
      bus: nil,
      bus_monitor: nil,
      subscription_id: Keyword.fetch!(opts, :subscription_id),
      path: Keyword.fetch!(opts, :path),
      selector: Keyword.fetch!(opts, :selector),
      retry: nil,
      delay: 100
    }

    send(consumer, {:messaging_subscription_started, self()})
    notify(state, false)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_info({:retry, token}, %{retry: {token, _timer}} = state), do: connect(%{state | retry: nil})

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{consumer_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{bus_monitor: ref} = state) do
    notify(state, false)
    {:noreply, retry(%{state | bus: nil, bus_monitor: nil, delay: 100})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.retry, do: Process.cancel_timer(elem(state.retry, 1))
    if state.bus, do: safely(fn -> Bus.unsubscribe(state.bus, state.subscription_id) end)
    :ok
  end

  defp connect(state) do
    case safely(fn -> Bus.whereis(state.bus_name) end) do
      {:ok, bus} -> subscribe(state, bus)
      _ -> {:noreply, retry(state)}
    end
  end

  defp subscribe(state, bus) do
    generation = Process.monitor(bus)

    opts = [
      subscription_id: state.subscription_id,
      target: state.consumer
    ]

    opts = if state.selector == [], do: opts, else: Keyword.put(opts, :selector, state.selector)

    # The ID is stable for this consumer. Remove a subscription left by a killed
    # worker before replacing it. A different worker cannot own the same key.
    result =
      safely(fn ->
        Bus.unsubscribe(bus, state.subscription_id)
        Bus.subscribe(bus, state.path, opts)
      end)

    case result do
      {:ok, _id} ->
        notify(state, true)
        {:noreply, %{state | bus: bus, bus_monitor: generation, delay: 100}}

      _ ->
        Process.demonitor(generation, [:flush])
        {:noreply, retry(state)}
    end
  end

  defp retry(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:retry, token}, state.delay)
    %{state | retry: {token, timer}, delay: min(state.delay * 2, 1_000)}
  end

  defp notify(state, subscribed), do: send(state.consumer, {:messaging_subscription_status, self(), subscribed})

  defp safely(fun) do
    fun.()
  rescue
    ArgumentError -> {:error, :bus_unavailable}
  catch
    :exit, _ -> {:error, :bus_unavailable}
  end
end
