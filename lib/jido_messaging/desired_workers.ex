defmodule Jido.Messaging.DesiredWorkers do
  @moduledoc false
  use GenServer

  # The instance supervisor owns the table. Registry and worker-group failure
  # cannot remove the desired start specifications. This worker serializes
  # explicit start/stop commands with recovery for one dynamic supervisor.
  @spec new(module()) :: atom()
  def new(instance), do: :ets.new(table_name(instance), [:named_table, :public, :set])

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :supervisor)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(Keyword.fetch!(opts, :supervisor)))

  @spec start(module(), atom(), term(), Supervisor.child_spec() | {module(), term()}) :: term()
  def start(instance, supervisor, key, spec) do
    manage(instance, supervisor, {:start, key, spec}, fn -> DynamicSupervisor.start_child(supervisor, spec) end)
  end

  @spec stop(module(), atom(), term(), pid()) :: :ok | {:error, term()}
  def stop(instance, supervisor, key, pid) do
    manage(instance, supervisor, {:stop, key, pid}, fn -> DynamicSupervisor.terminate_child(supervisor, pid) end)
  end

  @spec restore(atom()) :: :ok
  def restore(supervisor), do: GenServer.cast(name(supervisor), :restore)

  @impl true
  def init(opts) do
    state = %{supervisor: Keyword.fetch!(opts, :supervisor), table: Keyword.fetch!(opts, :table), retry: nil}
    {:ok, state, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state), do: {:noreply, restore_children(state)}

  @impl true
  def handle_call({:start, key, spec}, _from, state) do
    result = safely(fn -> DynamicSupervisor.start_child(state.supervisor, spec) end)

    if started?(result), do: :ets.insert(state.table, {{state.supervisor, key}, spec})
    {:reply, result, state}
  end

  def handle_call({:stop, key, pid}, _from, state) do
    result = safely(fn -> DynamicSupervisor.terminate_child(state.supervisor, pid) end)
    if result == :ok, do: :ets.delete(state.table, {state.supervisor, key})
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:restore, state), do: {:noreply, restore_children(state)}

  @impl true
  def handle_info({:restore, token}, %{retry: {token, _timer}} = state),
    do: {:noreply, restore_children(%{state | retry: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  defp restore_children(state) do
    restored =
      state.table
      |> :ets.match_object({{state.supervisor, :_}, :_})
      |> Enum.map(fn {_key, spec} ->
        case safely(fn -> DynamicSupervisor.start_child(state.supervisor, spec) end) do
          {:error, {:already_started, pid}} -> owned?(state.supervisor, pid)
          result -> started?(result)
        end
      end)

    if Enum.all?(restored), do: state, else: retry(state)
  end

  defp owned?(supervisor, pid) do
    case safely(fn -> DynamicSupervisor.which_children(supervisor) end) do
      children when is_list(children) -> Enum.any?(children, fn {_, child, _, _} -> child == pid end)
      _ -> false
    end
  end

  defp retry(%{retry: nil} = state) do
    token = make_ref()
    %{state | retry: {token, Process.send_after(self(), {:restore, token}, 100)}}
  end

  defp retry(state), do: state

  defp started?({:ok, _pid}), do: true
  defp started?({:ok, _pid, _info}), do: true
  defp started?(_result), do: false

  defp manage(instance, supervisor, message, standalone) do
    if :ets.whereis(table_name(instance)) == :undefined,
      do: standalone.(),
      else: safely(fn -> GenServer.call(name(supervisor), message, :infinity) end)
  end

  defp table_name(instance), do: Module.concat(instance, DesiredWorkerSpecs)
  defp name(supervisor), do: Module.concat(supervisor, DesiredWorkers)

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :supervisor_unavailable}
  end
end
