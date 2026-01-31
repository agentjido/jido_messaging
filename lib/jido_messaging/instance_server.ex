defmodule JidoMessaging.InstanceServer do
  @moduledoc """
  Per-instance GenServer that tracks lifecycle state and emits signals.

  The InstanceServer is the authoritative source for instance status.
  Channel processes (Poller, Sender) communicate state changes to the
  InstanceServer, which then emits appropriate telemetry signals.

  ## State Machine

      :starting -> :connecting -> :connected
                              |-> :disconnected <-> :connected
                              |-> :error

  ## Signals Emitted

  - `[:jido_messaging, :instance, :started]`
  - `[:jido_messaging, :instance, :connecting]`
  - `[:jido_messaging, :instance, :connected]`
  - `[:jido_messaging, :instance, :disconnected]`
  - `[:jido_messaging, :instance, :stopped]`
  - `[:jido_messaging, :instance, :error]`
  """
  use GenServer
  require Logger

  alias JidoMessaging.Instance

  @idle_timeout_ms :timer.minutes(30)

  defstruct [
    :instance_module,
    :instance,
    :status,
    :last_error,
    :connected_at,
    :started_at,
    consecutive_failures: 0
  ]

  # Client API

  def start_link(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    instance = Keyword.fetch!(opts, :instance)
    name = via_tuple(instance_module, instance.id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get the instance server pid"
  def whereis(instance_module, instance_id) do
    case Registry.lookup(registry_name(instance_module), {:instance, instance_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Get current instance status"
  @spec status(pid() | {module(), String.t()}) :: {:ok, map()} | {:error, :not_found}
  def status(pid) when is_pid(pid) do
    GenServer.call(pid, :status)
  end

  def status({instance_module, instance_id}) do
    case whereis(instance_module, instance_id) do
      nil -> {:error, :not_found}
      pid -> status(pid)
    end
  end

  @doc "Get the full instance struct"
  @spec get_instance(pid()) :: {:ok, Instance.t()}
  def get_instance(pid) do
    GenServer.call(pid, :get_instance)
  end

  @doc "Notify that the instance is connecting"
  def notify_connecting(pid) do
    GenServer.cast(pid, :connecting)
  end

  @doc "Notify that the instance is connected"
  def notify_connected(pid, meta \\ %{}) do
    GenServer.cast(pid, {:connected, meta})
  end

  @doc "Notify that the instance is disconnected"
  def notify_disconnected(pid, reason \\ :unknown) do
    GenServer.cast(pid, {:disconnected, reason})
  end

  @doc "Notify of a delivery or operation failure (increments failure counter)"
  def notify_failure(pid, reason) do
    GenServer.cast(pid, {:failure, reason})
  end

  @doc "Notify of a successful operation (resets failure counter)"
  def notify_success(pid) do
    GenServer.cast(pid, :success)
  end

  @doc "Gracefully stop the instance"
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  defp via_tuple(instance_module, instance_id) do
    {:via, Registry, {registry_name(instance_module), {:instance, instance_id}}}
  end

  defp registry_name(instance_module) do
    Module.concat(instance_module, Registry.Instances)
  end

  # Server implementation

  @impl true
  def init(opts) do
    instance_module = Keyword.fetch!(opts, :instance_module)
    instance = Keyword.fetch!(opts, :instance)

    state = %__MODULE__{
      instance_module: instance_module,
      instance: instance,
      status: :starting,
      started_at: DateTime.utc_now()
    }

    emit_signal(state, :started, %{
      instance_id: instance.id,
      channel_type: instance.channel_type,
      name: instance.name
    })

    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status_info = %{
      status: state.status,
      instance_id: state.instance.id,
      channel_type: state.instance.channel_type,
      name: state.instance.name,
      connected_at: state.connected_at,
      started_at: state.started_at,
      consecutive_failures: state.consecutive_failures,
      last_error: state.last_error
    }

    {:reply, {:ok, status_info}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:get_instance, _from, state) do
    {:reply, {:ok, state.instance}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    emit_signal(state, :stopped, %{instance_id: state.instance.id})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast(:connecting, state) do
    new_state = %{state | status: :connecting}
    emit_signal(new_state, :connecting, %{instance_id: state.instance.id})
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:connected, meta}, state) do
    new_state = %{
      state
      | status: :connected,
        connected_at: DateTime.utc_now(),
        consecutive_failures: 0,
        last_error: nil
    }

    emit_signal(new_state, :connected, Map.merge(%{instance_id: state.instance.id}, meta))
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:disconnected, reason}, state) do
    new_state = %{state | status: :disconnected, last_error: reason}
    emit_signal(new_state, :disconnected, %{instance_id: state.instance.id, reason: reason})
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:failure, reason}, state) do
    new_failures = state.consecutive_failures + 1
    new_status = if new_failures >= 10, do: :error, else: state.status

    new_state = %{
      state
      | consecutive_failures: new_failures,
        last_error: reason,
        status: new_status
    }

    if new_status == :error and state.status != :error do
      emit_signal(new_state, :error, %{
        instance_id: state.instance.id,
        error: reason,
        consecutive_failures: new_failures
      })
    end

    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast(:success, state) do
    new_state = %{state | consecutive_failures: 0}
    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state, :hibernate}
  end

  defp emit_signal(state, event, metadata) do
    :telemetry.execute(
      [:jido_messaging, :instance, event],
      %{system_time: System.system_time()},
      Map.put(metadata, :instance_module, state.instance_module)
    )
  end
end
