defmodule Jido.Messaging.SecurityBoundaryRegressionTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{Ingest, Moderators.RateLimiter, Security}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  defmodule Channel do
    use Jido.Chat.Adapter
    def channel_type, do: :security_boundary
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(_, _), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  defmodule Hook do
    def verify_sender(_, _, _, opts), do: invoke(opts, :ok)
    def sanitize_outbound(_, outbound, opts), do: invoke(opts, {:ok, outbound})

    defp invoke(opts, result) do
      case opts[:mode] do
        :fail ->
          {:error, :temporary_failure}

        :kill ->
          Process.exit(self(), :kill)

        :block ->
          send(opts[:notify], {:hook_worker, self()})
          receive do: (:release -> result)
      end
    end
  end

  setup do
    start_supervised!(Instance)
    :ok
  end

  test "rate counts survive the short moderation worker" do
    opts = [
      moderators: [RateLimiter],
      moderation_opts: [table: :security_boundary_rate_limits, max_messages: 1]
    ]

    RateLimiter.reset("sender", :security_boundary_rate_limits)

    assert {:ok, message, _} =
             Ingest.ingest_incoming(Instance, Channel, "bridge", incoming("one"), opts)

    assert {:error, {:policy_denied, :moderation, :rate_limited, _}} =
             Ingest.ingest_incoming(Instance, Channel, "bridge", incoming("two"), opts)

    assert RateLimiter.get_count(message.sender_id, table: :security_boundary_rate_limits) == 1
    on_exit(fn -> RateLimiter.reset(message.sender_id, :security_boundary_rate_limits) end)
  end

  test "invalid strict failure policies cannot allow failed verification or sanitization" do
    opts = [
      security: [
        adapter: Hook,
        adapter_opts: [mode: :fail],
        mode: :strict,
        verify_failure_policy: :invalid,
        sanitize_failure_policy: :invalid
      ]
    ]

    assert {:error, {:security_denied, :verify, _, _}} =
             Security.verify_sender(Instance, Channel, %{}, %{}, opts)

    assert {:error, {:security_denied, :sanitize, _, _}} =
             Security.sanitize_outbound(Instance, Channel, "original", opts)
  end

  for stage <- [:verify, :sanitize] do
    test "#{stage} deadline stops work while the caller is suspended" do
      notify = self()
      stage = unquote(stage)

      opts = [
        security: [
          adapter: Hook,
          adapter_opts: [mode: :block, notify: notify],
          mode: :strict,
          verify_timeout_ms: 80,
          sanitize_timeout_ms: 80
        ]
      ]

      caller = spawn(fn -> send(notify, {:hook_result, call(stage, opts)}) end)
      assert_receive {:hook_worker, worker}
      monitor = Process.monitor(worker)
      :erlang.suspend_process(caller)

      on_exit(fn ->
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        if Process.alive?(worker), do: Process.exit(worker, :kill)
      end)

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500
      :erlang.resume_process(caller)
      assert_receive {:hook_result, {:error, {:security_denied, _, {:security_failure, :retry}, _}}}
    end

    test "#{stage} worker stops when its caller dies" do
      notify = self()
      stage = unquote(stage)

      opts = [
        security: [
          adapter: Hook,
          adapter_opts: [mode: :block, notify: notify],
          verify_timeout_ms: 5_000,
          sanitize_timeout_ms: 5_000
        ]
      ]

      caller = spawn(fn -> call(stage, opts) end)
      assert_receive {:hook_worker, worker}
      monitor = Process.monitor(worker)
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
    end

    test "#{stage} callback kill does not kill its caller" do
      opts = [security: [adapter: Hook, adapter_opts: [mode: :kill], mode: :strict]]
      assert {:error, {:security_denied, _, _, _}} = call(unquote(stage), opts)
      refute_receive {:EXIT, _, _}, 0
      refute_receive {:DOWN, _, _, _, _}, 0
    end
  end

  defp call(:verify, opts), do: Security.verify_sender(Instance, Channel, %{}, %{}, opts)
  defp call(:sanitize, opts), do: Security.sanitize_outbound(Instance, Channel, "original", opts)

  defp incoming(id),
    do: %{external_room_id: "room", external_user_id: "sender", external_message_id: id, text: id}
end
