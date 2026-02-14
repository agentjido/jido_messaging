defmodule JidoMessaging.Onboarding do
  @moduledoc """
  Onboarding flow orchestration APIs.

  Flows are persisted in the configured storage adapter and executed by
  supervisor-managed workers keyed by onboarding ID.
  """

  alias JidoMessaging.Onboarding.Supervisor
  alias JidoMessaging.Onboarding.Worker
  alias JidoMessaging.Runtime

  @type transition :: JidoMessaging.Onboarding.StateMachine.transition()
  @worker_retry_attempts 3

  @doc "Start (or resume) an onboarding flow."
  @spec start(module(), map(), keyword()) :: {:ok, JidoMessaging.Onboarding.Flow.t()} | {:error, term()}
  def start(instance_module, attrs, opts \\ [])
      when is_atom(instance_module) and is_map(attrs) and is_list(opts) do
    onboarding_id = normalize_onboarding_id(attrs)
    start_request = Map.delete(attrs, :onboarding_id) |> Map.delete("onboarding_id")

    with_worker(instance_module, onboarding_id, [start_request: start_request], fn pid ->
      Worker.get_flow(pid)
    end)
  end

  @doc "Advance an onboarding flow with a deterministic transition."
  @spec advance(module(), String.t(), transition(), map(), keyword()) ::
          {:ok, %{required(:flow) => JidoMessaging.Onboarding.Flow.t(), required(:transition) => map()}}
          | {:error, term()}
  def advance(instance_module, onboarding_id, transition, metadata \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_atom(transition) and is_map(metadata) and
             is_list(opts) do
    with_worker(instance_module, onboarding_id, opts, fn pid ->
      Worker.transition(pid, transition, metadata, opts)
    end)
  end

  @doc "Resume an onboarding flow from persisted state."
  @spec resume(module(), String.t()) :: {:ok, JidoMessaging.Onboarding.Flow.t()} | {:error, term()}
  def resume(instance_module, onboarding_id)
      when is_atom(instance_module) and is_binary(onboarding_id) do
    with_worker(instance_module, onboarding_id, [], fn pid ->
      Worker.get_flow(pid)
    end)
  end

  @doc "Cancel an onboarding flow."
  @spec cancel(module(), String.t(), map(), keyword()) ::
          {:ok, %{required(:flow) => JidoMessaging.Onboarding.Flow.t(), required(:transition) => map()}}
          | {:error, term()}
  def cancel(instance_module, onboarding_id, metadata \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_map(metadata) and is_list(opts) do
    advance(instance_module, onboarding_id, :cancel, metadata, opts)
  end

  @doc "Complete an onboarding flow."
  @spec complete(module(), String.t(), map(), keyword()) ::
          {:ok, %{required(:flow) => JidoMessaging.Onboarding.Flow.t(), required(:transition) => map()}}
          | {:error, term()}
  def complete(instance_module, onboarding_id, metadata \\ %{}, opts \\ [])
      when is_atom(instance_module) and is_binary(onboarding_id) and is_map(metadata) and is_list(opts) do
    advance(instance_module, onboarding_id, :complete, metadata, opts)
  end

  @doc "Fetch onboarding flow state without changing worker state."
  @spec get(module(), String.t()) :: {:ok, JidoMessaging.Onboarding.Flow.t()} | {:error, term()}
  def get(instance_module, onboarding_id)
      when is_atom(instance_module) and is_binary(onboarding_id) do
    runtime = instance_module.__jido_messaging__(:runtime)
    {adapter, adapter_state} = Runtime.get_adapter(runtime)
    adapter.get_onboarding(adapter_state, onboarding_id)
  end

  @doc "Returns the PID for a flow worker, if it is currently running."
  @spec whereis_worker(module(), String.t()) :: pid() | nil
  def whereis_worker(instance_module, onboarding_id)
      when is_atom(instance_module) and is_binary(onboarding_id) do
    Worker.whereis(instance_module, onboarding_id)
  end

  defp normalize_onboarding_id(attrs) do
    case Map.get(attrs, :onboarding_id) || Map.get(attrs, "onboarding_id") do
      onboarding_id when is_binary(onboarding_id) and onboarding_id != "" -> onboarding_id
      _ -> Jido.Signal.ID.generate!()
    end
  end

  defp with_worker(instance_module, onboarding_id, opts, operation, attempt \\ 1)

  defp with_worker(instance_module, onboarding_id, opts, operation, attempt)
       when attempt <= @worker_retry_attempts do
    case Supervisor.get_or_start_worker(instance_module, onboarding_id, opts) do
      {:ok, pid} when is_pid(pid) ->
        case operation.(pid) do
          {:error, {:worker_unavailable, _reason}} when attempt < @worker_retry_attempts ->
            with_worker(instance_module, onboarding_id, opts, operation, attempt + 1)

          result ->
            result
        end

      {:error, :worker_unavailable} when attempt < @worker_retry_attempts ->
        with_worker(instance_module, onboarding_id, opts, operation, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
