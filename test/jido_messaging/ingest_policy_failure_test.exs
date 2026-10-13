defmodule Jido.Messaging.IngestPolicyFailureTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Ingest

  defmodule Runtime do
    use Jido.Messaging
  end

  defmodule Channel do
    use Jido.Chat.Adapter
    @impl true
    def channel_type, do: :policy_failure_test
    @impl true
    def signal_protocol, do: 1
    @impl true
    def configure_binding(opts), do: {:ok, opts}
    @impl true
    def normalize_event(_binding, _raw), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
  end

  defmodule Gater do
    @behaviour Jido.Messaging.Gating
    @impl true
    def check(_context, opts), do: fail(opts)

    def fail(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:policy_called, self()})

      case Keyword.fetch!(opts, :failure) do
        :raise -> raise "private policy failure"
        :throw -> throw(:private_policy_failure)
        :exit -> exit(:private_policy_failure)
        :kill -> Process.exit(self(), :kill)
        :block -> receive do: (:complete_policy -> :allow)
        result -> result
      end
    end
  end

  defmodule Moderator do
    @behaviour Jido.Messaging.Moderation
    @impl true
    def moderate(_message, opts), do: Gater.fail(opts)
  end

  setup do
    start_supervised!(Runtime)
    :ok
  end

  for stage <- [:gating, :moderation], failure <- [:raise, :throw, :exit, :kill, :invalid] do
    test "#{stage} #{failure} denial preserves retry ownership" do
      stage = unquote(stage)
      incoming = incoming()
      opts = policy_opts(stage, unquote(failure), :deny)

      assert {:error, {:policy_denied, ^stage, :policy_error, _description}} =
               Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming, opts)

      assert_receive {:policy_called, pid}
      refute Process.alive?(pid)

      assert {:error, :not_found} =
               Runtime.get_message_by_external_id(:policy_failure_test, "owned-bridge", "owned-message")

      assert {:ok, message, _context} = Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming)
      assert message.external_id == "owned-message"
      assert {:ok, :duplicate} = Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming)
      assert {:ok, [^message]} = Runtime.list_messages(message.room_id)
      refute_receive {:policy_called, _}, 0
      refute_receive {:EXIT, _, _}, 0
    end

    test "#{stage} #{failure} fallback retains one message" do
      stage = unquote(stage)
      opts = policy_opts(stage, unquote(failure), :allow_with_flag)
      assert {:ok, message, _context} = Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming(), opts)
      assert message.external_id == "owned-message"
      assert {:ok, [^message]} = Runtime.list_messages(message.room_id)
      assert message.metadata.policy.flagged == true
      assert Enum.any?(message.metadata.policy.flags, &(&1.stage == stage and &1.reason == :policy_error))
      assert_receive {:policy_called, _pid}
      assert {:ok, :duplicate} = Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming(), opts)
      refute_receive {:policy_called, _}, 0
    end
  end

  for stage <- [:gating, :moderation] do
    test "#{stage} timeout stops the policy and permits one retry" do
      stage = unquote(stage)
      opts = timeout_opts(stage)

      assert {:error, {:policy_denied, ^stage, :policy_timeout, _}} =
               Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming(), opts)

      assert_receive {:policy_called, pid}
      refute Process.alive?(pid)
      refute_receive {:DOWN, _, :process, ^pid, _}, 0

      assert {:error, :not_found} =
               Runtime.get_message_by_external_id(:policy_failure_test, "owned-bridge", "owned-message")

      assert {:ok, message, _} = Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming())
      assert {:ok, [^message]} = Runtime.list_messages(message.room_id)
      assert {:ok, :duplicate} = Ingest.ingest_incoming(Runtime, Channel, "owned-bridge", incoming())
    end
  end

  defp timeout_opts(:gating),
    do: [
      gaters: [Gater],
      gating_opts: [test_pid: self(), failure: :block],
      gating_timeout_ms: 30,
      policy_timeout_fallback: :deny
    ]

  defp timeout_opts(:moderation),
    do: [
      moderators: [Moderator],
      moderation_opts: [test_pid: self(), failure: :block],
      moderation_timeout_ms: 30,
      policy_timeout_fallback: :deny
    ]

  defp incoming do
    %{
      external_room_id: "owned-room",
      external_user_id: "owned-user",
      text: "owned payload",
      external_message_id: "owned-message"
    }
  end

  defp policy_opts(:gating, failure, fallback),
    do: [gaters: [Gater], gating_opts: [test_pid: self(), failure: failure], policy_error_fallback: fallback]

  defp policy_opts(:moderation, failure, fallback),
    do: [
      moderators: [Moderator],
      moderation_opts: [test_pid: self(), failure: failure],
      policy_error_fallback: fallback
    ]
end
