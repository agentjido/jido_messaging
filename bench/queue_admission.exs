defmodule QueueAdmissionProbe.Instance do
  use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
end

defmodule QueueAdmissionProbe.Adapter do
  use Jido.Chat.Adapter
  def signal_protocol, do: 1
  def configure_binding(opts), do: {:ok, opts}
  def normalize_event(_, _), do: {:error, :unused}
  def capabilities, do: %{send_message: :native}

  def send_message(_, text, opts) do
    attempt =
      Agent.get_and_update(opts[:counts], fn counts ->
        next = Map.get(counts, text, 0) + 1
        {next, Map.put(counts, text, next)}
      end)

    if text == "held", do: send(opts[:probe], {:held, self()})
    if text == "held", do: receive(do: (:release -> :ok))
    if text == "retry" and attempt == 1, do: {:error, :network_error}, else: {:ok, %{id: text}}
  end
end

defmodule QueueAdmissionProbe do
  alias Jido.Messaging.{ConfigStore, DeadLetter, OutboundGateway, Runtime}
  alias Jido.Messaging.OutboundGateway.{Admission, Partition}
  alias __MODULE__.{Adapter, Instance}

  def run do
    trials = for trial <- 1..5, do: burst(trial, false)
    delayed = burst(6, true)
    c5 = c5()
    control = delayed_control()

    report = %{
      trials: trials,
      delayed_dead_letter: delayed,
      c5: c5,
      delayed_control: control,
      host: :erlang.system_info(:system_architecture) |> to_string(),
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: System.schedulers_online(),
      latency_scope:
        "Prebuilt Partition.dispatch request: overload response only. Public accepted calls wait for completion.",
      healthy_target_passed: Enum.all?(trials, &(&1.rejected.p95_us < 50_000 and &1.rejected.p99_us < 100_000))
    }

    File.write!(System.fetch_env!("JIDO_QUEUE_REPORT"), Jason.encode!(report, pretty: true))
    IO.inspect(report, pretty: true)
    if not report.healthy_target_passed, do: raise("healthy rejection target missed")
  end

  defp start(capacity) do
    Application.put_env(Instance, :outbound_gateway,
      partition_count: 1,
      queue_capacity: capacity,
      base_backoff_ms: 200,
      max_backoff_ms: 200,
      pressure_policy: [shed_action: :none, degraded_action: :none]
    )

    {:ok, supervisor} = Instance.start_link([])
    {:ok, counts} = Agent.start_link(fn -> %{} end)
    runtime = Instance.__jido_messaging__(:runtime)
    {:ok, _} = Runtime.ensure_binding(runtime, Adapter, "probe", probe: self(), counts: counts)
    {supervisor, counts, Partition.whereis(Instance, 0)}
  end

  defp stop({supervisor, counts, _}) do
    Supervisor.stop(supervisor)
    Agent.stop(counts)
  end

  defp request(text),
    do: %{
      operation: :send,
      channel: Adapter,
      bridge_id: "probe",
      external_room_id: "room",
      payload: text,
      opts: [],
      priority: :high,
      routing_key: "probe:room"
    }

  defp burst(trial, delay?) do
    setup = start(64)
    {_, _, coordinator} = setup
    first = Task.async(fn -> Partition.dispatch(Instance, 0, request("held"), 60_000) end)

    worker =
      receive do
        {:held, worker} -> worker
      after
        5_000 -> raise "provider not held"
      end

    dead_letter = Process.whereis(DeadLetter.server_name(Instance))
    if delay?, do: :sys.suspend(dead_letter)
    parent = self()

    callers =
      for index <- 1..10_000 do
        spawn(fn ->
          receive do
            :start ->
              {elapsed, result} =
                :timer.tc(fn -> Partition.dispatch(Instance, 0, request("queued-#{index}"), 60_000) end)

              send(parent, {:measured, elapsed, result})
          end
        end)
      end

    Enum.each(callers, &send(&1, :start))

    rejected =
      for _ <- 1..9_937 do
        receive do
          {:measured, elapsed, {:error, %{reason: :queue_full}}} -> elapsed
        after
          30_000 -> raise "overflow waited for provider"
        end
      end

    {:ok, _, %{load: 64}} = Admission.snapshot(Instance, 0, coordinator)
    state = :sys.get_state(coordinator)
    true = state.queue_size == 63
    {:message_queue_len, mailbox} = Process.info(coordinator, :message_queue_len)
    pending = :ets.info(DeadLetter.RejectionBuffer.table(Instance), :size) - 2
    if delay?, do: :sys.resume(dead_letter)
    send(worker, :release)
    {:ok, _} = Task.await(first, 30_000)

    accepted =
      for _ <- 1..63 do
        receive do
          {:measured, elapsed, {:ok, _}} -> elapsed
        after
          30_000 -> raise "queue did not drain"
        end
      end

    wait(fn -> match?({:ok, _, %{load: 0}}, Admission.snapshot(Instance, 0, coordinator)) end)

    report = %{
      trial: trial,
      capacity: 64,
      burst: 10_000,
      held: 1,
      admitted_from_burst: 63,
      rejected_count: length(rejected),
      rejected: percentiles(rejected),
      accepted_completion: percentiles(accepted),
      permits_at_barrier: 64,
      queued_at_barrier: 63,
      coordinator_mailbox_at_barrier: mailbox,
      pending_rejections_at_barrier: pending,
      all_overflow_before_release: true,
      final_permits: 0
    }

    stop(setup)
    report
  end

  defp c5 do
    setup = start(2)
    {_, _, coordinator} = setup

    public_send = fn text ->
      OutboundGateway.send_message(Instance, %{channel: Adapter, bridge_id: "probe", external_room_id: "room"}, text)
    end

    first = Task.async(fn -> public_send.("held") end)

    worker =
      receive do
        {:held, worker} -> worker
      after
        5_000 -> raise "provider not held"
      end

    late =
      Task.async(fn ->
        try do
          Partition.dispatch(Instance, 0, request("late"), 20)
        catch
          :exit, {:timeout, _} -> :timed_out
        end
      end)

    :timed_out = Task.await(late)

    rejected =
      for _ <- 1..12 do
        {elapsed, {:error, %{reason: :queue_full}}} =
          :timer.tc(fn -> public_send.("full") end)

        elapsed
      end

    send(worker, :release)
    {:ok, _} = Task.await(first)
    wait(fn -> :sys.get_state(coordinator).active == nil end)
    retry = Task.async(fn -> public_send.("retry") end)
    wait(fn -> match?(%{active: %{timer: ref}} when is_reference(ref), :sys.get_state(coordinator)) end)
    later = Task.async(fn -> :timer.tc(fn -> public_send.("after-retry") end) end)
    wait(fn -> :sys.get_state(coordinator).queue_size == 1 end)

    {retry_rejection, {:error, %{reason: :queue_full}}} =
      :timer.tc(fn -> public_send.("full") end)

    {:ok, %{attempts: 2}} = Task.await(retry)
    {retry_queued_completion, {:ok, _}} = Task.await(later)
    {_, counts, _} = setup

    report = %{
      capacity: 2,
      burst: 12,
      rejection: percentiles(rejected),
      all_overflow_before_release: true,
      accepted_caller_timed_out: true,
      timed_out_accepted_provider_calls: Agent.get(counts, & &1["late"]),
      retry_rejection_us: retry_rejection,
      retry_queued_completion_us: retry_queued_completion,
      retry_attempts: Agent.get(counts, & &1["retry"])
    }

    stop(setup)
    report
  end

  defp delayed_control do
    setup = start(1)
    first = Task.async(fn -> Partition.dispatch(Instance, 0, request("held")) end)

    worker =
      receive do
        {:held, worker} -> worker
      after
        5_000 -> raise "provider not held"
      end

    config = Process.whereis(ConfigStore.name(Instance))
    :ok = :sys.suspend(config)

    public =
      Task.async(fn ->
        :timer.tc(fn ->
          OutboundGateway.send_message(
            Instance,
            %{channel: Adapter, bridge_id: "probe", external_room_id: "room"},
            "full"
          )
        end)
      end)

    wait(fn -> elem(Process.info(config, :message_queue_len), 1) > 0 end)

    {direct_us, {:error, %{reason: :queue_full}}} =
      :timer.tc(fn -> Partition.dispatch(Instance, 0, request("full")) end)

    Process.sleep(100)
    :ok = :sys.resume(config)
    {public_us, {:error, %{reason: :queue_full}}} = Task.await(public)
    send(worker, :release)
    {:ok, _} = Task.await(first)
    stop(setup)

    %{
      injected_control_delay_ms: 100,
      public_total_us: public_us,
      prebuilt_admission_us: direct_us,
      limitation: "Public request construction waits for ConfigStore before queue admission."
    }
  end

  defp wait(predicate, remaining \\ 5_000)
  defp wait(_predicate, 0), do: raise("barrier timeout")

  defp wait(predicate, remaining) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(1)
          wait(predicate, remaining - 1)
        )
  end

  defp percentiles(values) do
    values = Enum.sort(values)
    n = length(values)

    %{
      p50_us: Enum.at(values, max(ceil(n * 0.5) - 1, 0)),
      p95_us: Enum.at(values, max(ceil(n * 0.95) - 1, 0)),
      p99_us: Enum.at(values, max(ceil(n * 0.99) - 1, 0)),
      max_us: List.last(values)
    }
  end
end

QueueAdmissionProbe.run()
