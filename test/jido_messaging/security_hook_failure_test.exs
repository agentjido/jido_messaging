defmodule Jido.Messaging.SecurityHookFailureTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Security

  defmodule Instance do
  end

  defmodule Channel do
    use Jido.Chat.Adapter

    @impl true
    def channel_type, do: :security_hook_test
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    @impl true
    def send_message(room, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_called, room, text})
      {:ok, %{message_id: "owned-message"}}
    end
  end

  defmodule Runtime do
    use Jido.Messaging
  end

  defmodule FailureAdapter do
    @behaviour Jido.Messaging.Security

    @impl true
    def verify_sender(_channel, _incoming, _raw, opts), do: fail(opts)

    @impl true
    def sanitize_outbound(_channel, _outbound, opts), do: fail(opts)

    defp fail(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:security_hook_call, self()})

      case Keyword.fetch!(opts, :failure) do
        :raise -> raise "private security failure"
        :throw -> throw(:private_security_failure)
        :exit -> exit(:private_security_failure)
        :kill -> Process.exit(self(), :kill)
        :block -> receive do: (:complete_security_hook -> :ok)
        result -> result
      end
    end
  end

  for failure <- [:raise, :throw, :exit, :kill, :invalid, {:error, :timeout}] do
    test "#{inspect(failure)} verify failure preserves the caller and deny policy" do
      opts = security_opts(unquote(Macro.escape(failure)), verify_failure_policy: :deny)

      assert {:error, {:security_denied, :verify, {:security_failure, _class}, _description}} =
               Security.verify_sender(Instance, Channel, %{}, %{}, opts)

      assert_receive {:security_hook_call, pid}
      refute Process.alive?(pid)
      refute_receive {:security_hook_call, _}, 0
      refute_receive {:EXIT, _, _}, 0
    end

    test "#{inspect(failure)} sanitize failure preserves the caller and original policy" do
      opts = security_opts(unquote(Macro.escape(failure)), sanitize_failure_policy: :allow_original)

      assert {:ok, "owned payload", %{decision: decision, metadata: metadata}} =
               Security.sanitize_outbound(Instance, Channel, "owned payload", opts)

      assert decision.action == :allow_original
      assert metadata.fallback == true
      assert_receive {:security_hook_call, pid}
      refute Process.alive?(pid)
      refute_receive {:security_hook_call, _}, 0
      refute_receive {:EXIT, _, _}, 0
    end

    test "#{inspect(failure)} verify failure follows allow policy" do
      opts = security_opts(unquote(Macro.escape(failure)), verify_failure_policy: :allow)

      assert {:ok, %{decision: decision, metadata: metadata}} =
               Security.verify_sender(Instance, Channel, %{}, %{}, opts)

      assert decision.action == :allow
      assert decision.outcome == :allow_fallback
      assert metadata.fallback == true
      assert_receive {:security_hook_call, _pid}
      refute_receive {:security_hook_call, _}, 0
    end

    test "#{inspect(failure)} sanitize failure follows deny policy" do
      opts = security_opts(unquote(Macro.escape(failure)), sanitize_failure_policy: :deny)

      assert {:error, {:security_denied, :sanitize, {:security_failure, _class}, _description}} =
               Security.sanitize_outbound(Instance, Channel, "owned payload", opts)

      assert_receive {:security_hook_call, _pid}
      refute_receive {:security_hook_call, _}, 0
    end
  end

  for stage <- [:verify, :sanitize] do
    test "#{stage} timeout kills the hook and clears its monitor" do
      stage = unquote(stage)
      security = security_opts(:block, verify_failure_policy: :deny, sanitize_failure_policy: :deny)[:security]
      opts = [security: Keyword.put(security, :"#{stage}_timeout_ms", 30)]

      result = invoke_stage(stage, opts)

      assert {:error, {:security_denied, ^stage, {:security_failure, :retry}, _}} = result
      assert_receive {:security_hook_call, pid}
      refute Process.alive?(pid)
      refute_receive {:DOWN, _, :process, ^pid, _}, 0
      assert {:messages, []} = Process.info(self(), :messages)
    end
  end

  test "explicit denial overrides permissive verification policy" do
    opts = security_opts({:error, :unauthorized_sender}, verify_failure_policy: :allow)

    assert {:error, {:security_denied, :verify, {:security_failure, :deny}, _}} =
             Security.verify_sender(Instance, Channel, %{}, %{}, opts)
  end

  test "successful metadata stays with the selected hook" do
    assert {:ok, %{decision: decision, metadata: %{owned: true}}} =
             Security.verify_sender(Instance, Channel, %{}, %{}, security_opts({:ok, %{owned: true}}, []))

    assert decision.adapter == FailureAdapter
    assert decision.classification == :allow
    assert_receive {:security_hook_call, _pid}

    assert {:ok, "safe payload", %{decision: decision, metadata: %{changed: true, owned: true}}} =
             Security.sanitize_outbound(
               Instance,
               Channel,
               "owned payload",
               security_opts({:ok, "safe payload", %{owned: true}}, [])
             )

    assert decision.adapter == FailureAdapter
    assert decision.action == :allow
    assert_receive {:security_hook_call, _pid}
    refute_receive {:security_hook_call, _}, 0
  end

  test "failed verification rejects ingest before canonical records" do
    start_supervised!(Runtime)

    incoming = %{
      external_room_id: "owned-room",
      external_user_id: "owned-user",
      text: "owned payload",
      external_message_id: "owned-message"
    }

    assert {:error, {:security_denied, :verify, {:security_failure, :retry}, _}} =
             Jido.Messaging.Ingest.ingest_incoming(
               Runtime,
               Channel,
               "owned-bridge",
               incoming,
               security_opts(:raise, verify_failure_policy: :deny)
             )

    assert {:error, :not_found} =
             Runtime.get_room_by_external_binding(:security_hook_test, "owned-bridge", "owned-room")

    assert {:error, :not_found} =
             Runtime.get_message_by_external_id(:security_hook_test, "owned-bridge", "owned-message")

    assert_receive {:security_hook_call, _pid}
    refute_receive {:provider_called, _, _}, 0
  end

  test "failed sanitization denies provider calls and keeps the gateway alive" do
    start_supervised!(Runtime)
    context = %{channel: Channel, bridge_id: "owned-bridge", external_room_id: "owned-room"}

    assert {:error, error} =
             Jido.Messaging.OutboundGateway.send_message(
               Runtime,
               context,
               "owned payload",
               security_opts(:raise, sanitize_failure_policy: :deny) ++ [test_pid: self(), max_attempts: 1]
             )

    assert {:security_denied, :sanitize, {:security_failure, :retry}, _} = error.reason
    assert error.category == :retryable
    assert_receive {:security_hook_call, _pid}
    refute_receive {:provider_called, _, _}, 0

    assert {:ok, result} =
             Jido.Messaging.OutboundGateway.send_message(Runtime, context, "safe payload", test_pid: self())

    assert result.message_id == "owned-message"
    assert_receive {:provider_called, "owned-room", "safe payload"}
    refute_receive {:provider_called, _, _}, 0
  end

  defp invoke_stage(:verify, opts), do: Security.verify_sender(Instance, Channel, %{}, %{}, opts)
  defp invoke_stage(:sanitize, opts), do: Security.sanitize_outbound(Instance, Channel, "owned payload", opts)

  defp security_opts(failure, policy) do
    [
      security:
        [
          adapter: FailureAdapter,
          adapter_opts: [failure: failure, test_pid: self()],
          verify_timeout_ms: 1_000,
          sanitize_timeout_ms: 1_000
        ] ++ policy
    ]
  end
end
