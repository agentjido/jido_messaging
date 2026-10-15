defmodule Jido.Messaging.CheckpointReconnectContractTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{Instance, InstanceReconnectWorker}

  defmodule Health do
    def check_health(instance) do
      case Agent.get(instance.settings.control, & &1) do
        :raise -> raise "fixture health failure"
        :throw -> throw(:fixture_health_failure)
        result -> result
      end
    end
  end

  defmodule Recorder do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, [])
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_cast(event, state), do: {:noreply, state ++ [event]}
    @impl true
    def handle_call(:events, _from, state), do: {:reply, state, state}
  end

  setup do
    control = start_supervised!({Agent, fn -> :ok end})
    recorder = start_supervised!(Recorder)

    instance =
      Instance.new(%{
        name: "fixture",
        channel_type: :internal,
        settings: %{
          control: control,
          probe_interval_ms: 60_000,
          reconnect_base_backoff_ms: 60_000,
          reconnect_max_backoff_ms: 60_000,
          reconnect_jitter_ratio: 0,
          max_reconnect_attempts: 2
        }
      })

    worker =
      start_supervised!(
        {InstanceReconnectWorker,
         instance_module: __MODULE__, instance: instance, instance_server: recorder, channel_module: Health}
      )

    {:ok, control: control, recorder: recorder, worker: worker}
  end

  defp tick(context, message) do
    send(context.worker, message)
    state = :sys.get_state(context.worker)
    events = GenServer.call(context.recorder, :events)
    {state, events}
  end

  test "a failed probe schedules one reconnect and a successful attempt clears its state", context do
    Agent.update(context.control, fn _ -> {:error, :timeout} end)
    {state, _events} = tick(context, :probe)
    assert state.phase == :reconnecting
    assert state.current_attempt == 1
    assert state.reconnect_reason == :timeout
    Agent.update(context.control, fn _ -> :ok end)
    {state, events} = tick(context, {:reconnect, 1, :timeout, System.monotonic_time(:millisecond)})
    assert state.phase == :connected
    assert state.current_attempt == 0
    assert state.reconnect_reason == nil
    assert Enum.any?(events, &match?({:connected, %{attempts: 1}}, &1))
  end

  test "recoverable retry stays bounded and a degraded retry returns to probes", context do
    Agent.update(context.control, fn _ -> {:error, :timeout} end)
    {state, _} = tick(context, {:reconnect, 1, :timeout, nil})
    assert state.phase == :reconnecting
    assert state.current_attempt == 2
    Agent.update(context.control, fn _ -> {:error, :unsupported} end)
    {state, _} = tick(context, {:reconnect, 2, :timeout, nil})
    assert state.phase == :degraded
    assert state.current_attempt == 0
  end

  for {result, message, reason} <- [
        {{:error, :timeout}, {:reconnect, 2, :timeout, nil}, {:shutdown, :reconnect_exhausted}},
        {{:error, :invalid}, :probe, {:shutdown, {:fatal_probe, :invalid}}},
        {{:error, :invalid}, {:reconnect, 1, :timeout, nil}, {:shutdown, {:fatal_reconnect, :invalid}}},
        {:throw, :probe, {:shutdown, {:fatal_probe, {:throw, :fixture_health_failure}}}}
      ] do
    test "terminal health #{inspect(result)} on #{inspect(message)} stops only its owned worker", context do
      Agent.update(context.control, fn _ -> unquote(Macro.escape(result)) end)
      monitor = Process.monitor(context.worker)
      send(context.worker, unquote(Macro.escape(message)))
      assert_receive {:DOWN, ^monitor, :process, _, unquote(Macro.escape(reason))}
      events = GenServer.call(context.recorder, :events)
      assert Enum.any?(events, &match?({:failure, _}, &1))
      assert Process.alive?(context.control)
      assert Process.alive?(context.recorder)
    end
  end

  test "exceptions use recoverable classification and a degraded probe never issues a reconnect", context do
    Agent.update(context.control, fn _ -> :raise end)
    {state, _} = tick(context, :probe)
    assert state.phase == :reconnecting
    Agent.update(context.control, fn _ -> {:error, :unsupported} end)
    {state, _} = tick(context, :probe)
    assert state.phase == :degraded
    assert state.current_attempt == 0
  end
end
