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

  @schema Zoi.struct(
            __MODULE__,
            %{
              instance_module: Zoi.any(),
              instance: Zoi.struct(Instance),
              status: Zoi.enum([:starting, :connecting, :connected, :disconnected, :error]) |> Zoi.default(:starting),
              last_error: Zoi.any() |> Zoi.nullish(),
              connected_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              started_at: Zoi.struct(DateTime) |> Zoi.nullish(),
              consecutive_failures: Zoi.integer() |> Zoi.default(0),
              reconnect_attempt: Zoi.integer() |> Zoi.default(0),
              restart_count: Zoi.integer() |> Zoi.default(0),
              last_restart_reason: Zoi.any() |> Zoi.nullish(),
              last_restart_class: Zoi.enum([:recoverable, :fatal]) |> Zoi.nullish(),
              stopped_emitted: Zoi.boolean() |> Zoi.default(false)
            },
            coerce: false
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema"
  def schema, do: @schema

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

  @doc "Record reconnect attempt progress for lifecycle observability"
  @spec notify_reconnect_attempt(pid(), non_neg_integer(), term() | nil) :: :ok
  def notify_reconnect_attempt(pid, attempt, reason \\ nil) do
    GenServer.cast(pid, {:reconnect_attempt, attempt, reason})
  end

  @doc "Record a restart marker before lifecycle workers crash/escalate"
  @spec notify_restart_marker(pid(), :recoverable | :fatal, term()) :: :ok
  def notify_restart_marker(pid, failure_class, reason)
      when failure_class in [:recoverable, :fatal] do
    GenServer.cast(pid, {:restart_marker, failure_class, reason})
  end

  @doc "Gracefully stop the instance"
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Get a health snapshot for the instance.

  Returns a map with:
  - `:status` - current status (:connected, :disconnected, :error, etc.)
  - `:instance_id` - the instance ID
  - `:channel_type` - the channel type atom
  - `:name` - the instance name
  - `:uptime_ms` - milliseconds since the instance started
  - `:connected_at` - DateTime when connected (or nil)
  - `:last_error` - the last error (or nil)
  - `:consecutive_failures` - number of consecutive failures
  - `:sender_queue_depth` - queue depth of sender (if available)
  """
  @spec health_snapshot(pid()) :: {:ok, map()}
  def health_snapshot(pid) do
    GenServer.call(pid, :health_snapshot)
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

    state =
      struct!(__MODULE__, %{
        instance_module: instance_module,
        instance: instance,
        status: :starting,
        started_at: DateTime.utc_now()
      })

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
      last_error: state.last_error,
      reconnect_attempt: state.reconnect_attempt,
      restart_count: state.restart_count,
      last_restart_reason: state.last_restart_reason,
      last_restart_class: state.last_restart_class,
      child_health_summary: child_health_summary(state)
    }

    {:reply, {:ok, status_info}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:get_instance, _from, state) do
    {:reply, {:ok, state.instance}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:health_snapshot, _from, state) do
    now = DateTime.utc_now()
    uptime_ms = DateTime.diff(now, state.started_at, :millisecond)

    sender_queue_depth = get_sender_queue_depth(state)

    snapshot = %{
      status: state.status,
      instance_id: state.instance.id,
      channel_type: state.instance.channel_type,
      name: state.instance.name,
      uptime_ms: uptime_ms,
      connected_at: state.connected_at,
      last_error: state.last_error,
      consecutive_failures: state.consecutive_failures,
      reconnect_attempt: state.reconnect_attempt,
      restart_count: state.restart_count,
      last_restart_reason: state.last_restart_reason,
      last_restart_class: state.last_restart_class,
      sender_queue_depth: sender_queue_depth,
      child_health_summary: child_health_summary(state)
    }

    {:reply, {:ok, snapshot}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    emit_signal(state, :stopped, %{instance_id: state.instance.id})
    {:stop, :normal, :ok, %{state | stopped_emitted: true}}
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
        last_error: nil,
        reconnect_attempt: 0
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
  def handle_cast({:reconnect_attempt, attempt, reason}, state) do
    new_status = if attempt > 0, do: :connecting, else: state.status

    new_state = %{
      state
      | reconnect_attempt: attempt,
        last_error: if(is_nil(reason), do: state.last_error, else: reason),
        status: new_status
    }

    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:restart_marker, failure_class, reason}, state) do
    new_state = %{
      state
      | restart_count: state.restart_count + 1,
        last_restart_reason: reason,
        last_restart_class: failure_class
    }

    {:noreply, new_state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state, :hibernate}
  end

  @impl true
  def terminate(reason, state) do
    if not state.stopped_emitted do
      emit_signal(state, :stopped, %{instance_id: state.instance.id, reason: reason})
    end

    :ok
  end

  defp emit_signal(state, event, metadata) do
    timestamp = DateTime.utc_now()

    base_metadata = %{
      instance_module: state.instance_module,
      channel_type: state.instance.channel_type,
      timestamp: timestamp
    }

    :telemetry.execute(
      [:jido_messaging, :instance, event],
      %{timestamp: timestamp},
      Map.merge(base_metadata, metadata)
    )
  end

  defp get_sender_queue_depth(state) do
    case JidoMessaging.Sender.whereis(state.instance_module, state.instance.id) do
      nil -> 0
      pid -> JidoMessaging.Sender.queue_size(pid)
    end
  end

  defp child_health_summary(state) do
    instance_supervisor_name = Module.concat([state.instance_module, Instance, state.instance.id])

    case Process.whereis(instance_supervisor_name) do
      nil ->
        %{status: :missing, total_children: 0, running_children: 0, children: %{}}

      supervisor_pid ->
        children =
          Supervisor.which_children(supervisor_pid)
          |> Enum.map(fn {id, pid, _type, _modules} ->
            {normalize_child_id(id), child_status(pid)}
          end)

        running_children =
          Enum.count(children, fn {_id, status} ->
            status in [:up, :restarting]
          end)

        %{
          status: :ok,
          total_children: length(children),
          running_children: running_children,
          children: Map.new(children)
        }
    end
  end

  defp normalize_child_id(id) when is_atom(id), do: id
  defp normalize_child_id(id), do: inspect(id)

  defp child_status(:restarting), do: :restarting
  defp child_status(pid) when is_pid(pid), do: if(Process.alive?(pid), do: :up, else: :down)
  defp child_status(_), do: :down
end
