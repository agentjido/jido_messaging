defmodule JidoMessaging.Onboarding.Worker do
  @moduledoc false
  use GenServer

  alias JidoMessaging.Onboarding.Flow
  alias JidoMessaging.Onboarding.StateMachine
  alias JidoMessaging.Runtime

  @default_call_timeout 5_000

  @type state :: %{
          instance_module: module(),
          onboarding_id: String.t(),
          flow: Flow.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    onboarding_id = Keyword.fetch!(opts, :onboarding_id)
    name = via_tuple(instance_module, onboarding_id)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec whereis(module(), String.t()) :: pid() | nil
  def whereis(instance_module, onboarding_id) when is_atom(instance_module) and is_binary(onboarding_id) do
    registry = registry_name(instance_module)

    case Registry.lookup(registry, {:onboarding_worker, onboarding_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec get_flow(pid(), timeout()) :: {:ok, Flow.t()} | {:error, term()}
  def get_flow(pid, timeout \\ @default_call_timeout) when is_pid(pid) do
    GenServer.call(pid, :get_flow, timeout)
  end

  @spec transition(pid(), StateMachine.transition(), map(), keyword(), timeout()) ::
          {:ok, %{required(:flow) => Flow.t(), required(:transition) => StateMachine.transition_result()}}
          | {:error, term()}
  def transition(pid, transition, metadata, opts \\ [], timeout \\ @default_call_timeout)
      when is_pid(pid) and is_atom(transition) and is_map(metadata) and is_list(opts) do
    GenServer.call(pid, {:transition, transition, metadata, opts}, timeout)
  end

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    onboarding_id = Keyword.fetch!(opts, :onboarding_id)
    start_request = Keyword.get(opts, :start_request)

    case restore_or_initialize_flow(instance_module, onboarding_id, start_request) do
      {:ok, flow} ->
        {:ok, %{instance_module: instance_module, onboarding_id: onboarding_id, flow: flow}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_flow, _from, state) do
    {:reply, {:ok, state.flow}, state}
  end

  @impl true
  def handle_call({:transition, transition, metadata, opts}, _from, state) do
    case StateMachine.transition(state.flow, transition, metadata, opts) do
      {:ok, next_flow, result} ->
        case maybe_persist_flow(state.instance_module, state.flow, next_flow) do
          :ok ->
            {:reply, {:ok, %{flow: next_flow, transition: result}}, %{state | flow: next_flow}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp restore_or_initialize_flow(instance_module, onboarding_id, start_request) do
    case fetch_flow(instance_module, onboarding_id) do
      {:ok, flow} ->
        {:ok, normalize_flow(flow)}

      {:error, :not_found} when is_map(start_request) ->
        flow = Flow.new(%{onboarding_id: onboarding_id, request: start_request})

        case persist_flow(instance_module, flow) do
          :ok -> {:ok, flow}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp maybe_persist_flow(_instance_module, previous_flow, next_flow) when previous_flow == next_flow, do: :ok

  defp maybe_persist_flow(instance_module, _previous_flow, next_flow) do
    persist_flow(instance_module, next_flow)
  end

  defp persist_flow(instance_module, flow) do
    with {adapter, adapter_state} <- runtime_adapter(instance_module),
         {:ok, _flow} <- adapter.save_onboarding(adapter_state, flow) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_flow(instance_module, onboarding_id) do
    {adapter, adapter_state} = runtime_adapter(instance_module)
    adapter.get_onboarding(adapter_state, onboarding_id)
  end

  defp runtime_adapter(instance_module) do
    runtime = instance_module.__jido_messaging__(:runtime)
    Runtime.get_adapter(runtime)
  end

  defp normalize_flow(%Flow{} = flow), do: flow

  defp normalize_flow(flow) when is_map(flow) do
    struct!(Flow, Map.new(flow))
  end

  defp registry_name(instance_module), do: Module.concat(instance_module, Registry.Onboarding)

  defp via_tuple(instance_module, onboarding_id) do
    {:via, Registry, {registry_name(instance_module), {:onboarding_worker, onboarding_id}}}
  end
end
