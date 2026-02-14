defmodule JidoMessaging.SecurityTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Security

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  defmodule SlackChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :slack

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room, _text, _opts), do: {:ok, %{message_id: "sent"}}
  end

  defmodule SlowAdapter do
    @behaviour JidoMessaging.Security

    @impl true
    def verify_sender(_channel_module, _incoming_message, _raw_payload, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 150))
      :ok
    end

    @impl true
    def sanitize_outbound(_channel_module, outbound, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 150))
      {:ok, outbound <> "_slow"}
    end
  end

  describe "verify_sender/5" do
    test "allows valid sender identity claim and returns decision metadata" do
      incoming = %{
        external_room_id: "room",
        external_user_id: "user_1",
        text: "hello"
      }

      raw_payload = %{claimed_sender_id: "user_1"}

      assert {:ok, %{decision: decision, metadata: metadata}} =
               Security.verify_sender(TestMessaging, SlackChannel, incoming, raw_payload)

      assert decision.stage == :verify
      assert decision.classification == :allow
      assert decision.action == :allow
      assert metadata == %{}
    end

    test "denies spoofed sender claim with typed reason" do
      incoming = %{
        external_room_id: "room",
        external_user_id: "trusted_user",
        text: "hello"
      }

      raw_payload = %{claimed_sender_id: "spoofed_user"}

      assert {:error, {:security_denied, :verify, :sender_claim_mismatch, description}} =
               Security.verify_sender(TestMessaging, SlackChannel, incoming, raw_payload)

      assert is_binary(description)
    end

    test "timeouts are bounded and can be denied by policy" do
      incoming = %{
        external_room_id: "room",
        external_user_id: "user_1",
        text: "hello"
      }

      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:security_denied, :verify, {:security_failure, :retry}, _description}} =
               Security.verify_sender(TestMessaging, SlackChannel, incoming, %{},
                 security: [
                   adapter: SlowAdapter,
                   adapter_opts: [sleep_ms: 250],
                   verify_timeout_ms: 20,
                   verify_failure_policy: :deny
                 ]
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 150
    end
  end

  describe "sanitize_outbound/4" do
    test "applies deterministic slack sanitization rules" do
      outbound = "hello @here\r\n<!channel>\x00"

      assert {:ok, sanitized, %{decision: decision, metadata: metadata}} =
               Security.sanitize_outbound(TestMessaging, SlackChannel, outbound)

      assert sanitized == "hello @ here\n<! channel>"
      assert decision.stage == :sanitize
      assert decision.outcome == :sanitized
      assert metadata.changed == true
      assert metadata.channel_rule == :neutralize_mass_mentions
    end

    test "timeouts can degrade by allowing original payload under policy" do
      outbound = "unsafe payload"

      assert {:ok, sanitized, %{decision: decision, metadata: metadata}} =
               Security.sanitize_outbound(TestMessaging, SlackChannel, outbound,
                 security: [
                   adapter: SlowAdapter,
                   adapter_opts: [sleep_ms: 250],
                   sanitize_timeout_ms: 20,
                   sanitize_failure_policy: :allow_original
                 ]
               )

      assert sanitized == outbound
      assert decision.classification == :retry
      assert decision.action == :allow_original
      assert decision.outcome == :allow_original_fallback
      assert metadata.fallback == true
    end
  end

  describe "security telemetry" do
    test "emits decision telemetry for verify and sanitize" do
      test_pid = self()
      handler_id = "security-decision-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :security, :decision],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:security_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      incoming = %{
        external_room_id: "room",
        external_user_id: "trusted_user",
        text: "hello"
      }

      _ = Security.verify_sender(TestMessaging, SlackChannel, incoming, %{claimed_sender_id: "spoofed_user"})
      _ = Security.sanitize_outbound(TestMessaging, SlackChannel, "hello @here")

      assert_receive {:security_event, [:jido_messaging, :security, :decision], %{elapsed_ms: elapsed_ms},
                      %{stage: :verify, classification: :deny, action: :deny, instance_module: TestMessaging}},
                     250

      assert is_integer(elapsed_ms)

      assert_receive {:security_event, [:jido_messaging, :security, :decision], %{elapsed_ms: elapsed_ms},
                      %{stage: :sanitize, classification: :allow, action: :allow, instance_module: TestMessaging}},
                     250

      assert is_integer(elapsed_ms)
    end
  end
end
