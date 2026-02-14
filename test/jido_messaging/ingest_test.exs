defmodule JidoMessaging.IngestTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.{Ingest, Message}

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  defmodule MockChannel do
    @behaviour JidoMessaging.Channel

    @impl true
    def channel_type, do: :mock

    @impl true
    def transform_incoming(_), do: {:error, :not_implemented}

    @impl true
    def send_message(_chat_id, _text, _opts), do: {:ok, %{message_id: 999}}
  end

  defmodule AllowGater do
    @behaviour JidoMessaging.Gating

    @impl true
    def check(_ctx, _opts), do: :allow
  end

  defmodule DenyGater do
    @behaviour JidoMessaging.Gating

    @impl true
    def check(_ctx, _opts), do: {:deny, :denied, "Denied by gater"}
  end

  defmodule TimeoutGater do
    @behaviour JidoMessaging.Gating

    @impl true
    def check(_ctx, opts) do
      sleep_ms = Keyword.get(opts, :sleep_ms, 200)
      Process.sleep(sleep_ms)
      :allow
    end
  end

  defmodule TrackingGater do
    @behaviour JidoMessaging.Gating

    @impl true
    def check(_ctx, opts) do
      if tracker = Keyword.get(opts, :tracker) do
        Agent.update(tracker, &[:gating | &1])
      end

      :allow
    end
  end

  defmodule AllowModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(_message, _opts), do: :allow
  end

  defmodule FlagModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(_message, _opts), do: {:flag, :unsafe_hint, "Needs review"}
  end

  defmodule ModifyModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(%Message{} = message, _opts) do
      modified =
        %{
          message
          | content: [%JidoMessaging.Content.Text{text: "[redacted]"}],
            metadata: Map.put(message.metadata, :moderation_note, "redacted")
        }

      {:modify, modified}
    end
  end

  defmodule TimeoutModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(_message, opts) do
      sleep_ms = Keyword.get(opts, :sleep_ms, 200)
      Process.sleep(sleep_ms)
      :allow
    end
  end

  defmodule TrackingModerator do
    @behaviour JidoMessaging.Moderation

    @impl true
    def moderate(message, opts) do
      if tracker = Keyword.get(opts, :tracker) do
        Agent.update(tracker, &[:moderation | &1])
      end

      {:modify, %{message | metadata: Map.put(message.metadata, :tracked, true)}}
    end
  end

  defmodule SlowSecurityAdapter do
    @behaviour JidoMessaging.Security

    @impl true
    def verify_sender(_channel_module, _incoming_message, _raw_payload, opts) do
      Process.sleep(Keyword.get(opts, :sleep_ms, 200))
      :ok
    end

    @impl true
    def sanitize_outbound(_channel_module, outbound, _opts) do
      {:ok, outbound}
    end
  end

  setup do
    start_supervised!(TestMessaging)
    TestMessaging.clear_dedupe()
    :ok
  end

  describe "ingest_incoming/4" do
    test "creates room, participant, and message" do
      incoming = %{
        external_room_id: "chat_123",
        external_user_id: "user_456",
        text: "Hello world!",
        username: "testuser",
        display_name: "Test User",
        external_message_id: 789,
        timestamp: 1_706_745_600,
        chat_type: :private
      }

      assert {:ok, message, context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "instance_1", incoming)

      assert message.role == :user
      assert message.status == :sent
      assert [%JidoMessaging.Content.Text{text: "Hello world!"}] = message.content
      assert message.metadata.external_message_id == 789
      assert message.metadata.timestamp == 1_706_745_600

      assert context.room.id == message.room_id
      assert context.participant.id == message.sender_id
      assert context.channel == MockChannel
      assert context.instance_id == "instance_1"
      assert context.external_room_id == "chat_123"
      assert context.instance_module == TestMessaging
    end

    test "context includes instance_module for signal emission" do
      incoming = %{
        external_room_id: "chat_signal",
        external_user_id: "user_signal",
        text: "Signal test",
        external_message_id: 9999
      }

      {:ok, _message, context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "signal_inst", incoming)

      # instance_module is required for Signal.emit_received to find the Signal Bus
      assert context.instance_module == TestMessaging
      assert is_atom(context.instance_module)
    end

    test "reuses existing room for same external binding" do
      incoming = %{
        external_room_id: "chat_same",
        external_user_id: "user_1",
        text: "First message",
        external_message_id: 1001
      }

      {:ok, msg1, ctx1} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming)

      incoming2 = %{
        external_room_id: "chat_same",
        external_user_id: "user_2",
        text: "Second message",
        external_message_id: 1002
      }

      {:ok, msg2, ctx2} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming2)

      assert msg1.room_id == msg2.room_id
      assert ctx1.room.id == ctx2.room.id
    end

    test "reuses existing participant for same external user" do
      incoming1 = %{
        external_room_id: "chat_1",
        external_user_id: "same_user",
        text: "Message 1",
        external_message_id: 2001
      }

      {:ok, msg1, _ctx1} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming1)

      incoming2 = %{
        external_room_id: "chat_2",
        external_user_id: "same_user",
        text: "Message 2",
        external_message_id: 2002
      }

      {:ok, msg2, _ctx2} = Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming2)

      assert msg1.sender_id == msg2.sender_id
    end

    test "creates different rooms for different instances" do
      incoming_a = %{
        external_room_id: "chat_x",
        external_user_id: "user_x",
        text: "Test",
        external_message_id: 3001
      }

      incoming_b = %{
        external_room_id: "chat_x",
        external_user_id: "user_x",
        text: "Test",
        external_message_id: 3002
      }

      {:ok, msg1, _} = Ingest.ingest_incoming(TestMessaging, MockChannel, "instance_a", incoming_a)
      {:ok, msg2, _} = Ingest.ingest_incoming(TestMessaging, MockChannel, "instance_b", incoming_b)

      assert msg1.room_id != msg2.room_id
    end

    test "handles message without text" do
      incoming = %{
        external_room_id: "chat_no_text",
        external_user_id: "user_no_text",
        text: nil,
        external_message_id: 4001
      }

      {:ok, message, _context} =
        Ingest.ingest_incoming(TestMessaging, MockChannel, "inst", incoming)

      assert message.content == []
    end

    test "maps chat types to room types correctly" do
      msg_id = 5000

      for {chat_type, expected_room_type} <- [
            {:private, :direct},
            {:group, :group},
            {:supergroup, :group},
            {:channel, :channel}
          ] do
        incoming = %{
          external_room_id: "chat_#{chat_type}",
          external_user_id: "user_type_test",
          text: "Test",
          chat_type: chat_type,
          external_message_id: msg_id + :erlang.phash2(chat_type)
        }

        {:ok, _msg, context} =
          Ingest.ingest_incoming(TestMessaging, MockChannel, "type_inst", incoming)

        assert context.room.type == expected_room_type,
               "Expected #{expected_room_type} for chat_type #{chat_type}"
      end
    end
  end

  describe "ingest_incoming/5 policy pipeline" do
    test "runs gating before moderation deterministically with configured modules" do
      {:ok, tracker} = Agent.start_link(fn -> [] end)

      incoming = %{
        external_room_id: "chat_policy_order",
        external_user_id: "user_policy_order",
        text: "Policy order check",
        external_message_id: 6001
      }

      assert {:ok, message, _context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "policy_inst", incoming,
                 gaters: [TrackingGater],
                 gating_opts: [tracker: tracker],
                 moderators: [TrackingModerator],
                 moderation_opts: [tracker: tracker]
               )

      assert message.metadata[:tracked] == true
      assert Agent.get(tracker, &Enum.reverse(&1)) == [:gating, :moderation]
    end

    test "denied messages are not persisted and do not emit room/message signals" do
      test_pid = self()
      handler_id = "ingest-policy-deny-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:jido_messaging, :room, :message_added],
          [:jido_messaging, :message, :received]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      incoming = %{
        external_room_id: "chat_policy_deny",
        external_user_id: "user_policy_deny",
        text: "Should be denied",
        external_message_id: 6002
      }

      assert {:error, {:policy_denied, :gating, :denied, "Denied by gater"}} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "policy_inst", incoming, gaters: [DenyGater])

      assert {:ok, room} =
               TestMessaging.get_room_by_external_binding(:mock, "policy_inst", "chat_policy_deny")

      assert {:ok, []} = TestMessaging.list_messages(room.id)
      assert {:error, :not_found} = TestMessaging.get_message_by_external_id(:mock, "policy_inst", 6002)

      refute_receive {:telemetry_event, [:jido_messaging, :room, :message_added], _, %{instance_module: TestMessaging}},
                     150

      refute_receive {:telemetry_event, [:jido_messaging, :message, :received], _, %{instance_module: TestMessaging}},
                     150
    end

    test "policy timeouts are bounded and can deny quickly" do
      incoming = %{
        external_room_id: "chat_policy_timeout_deny",
        external_user_id: "user_policy_timeout_deny",
        text: "Timeout gater",
        external_message_id: 6003
      }

      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:policy_denied, :gating, :policy_timeout, "Policy module timed out"}} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "policy_inst", incoming,
                 gaters: [TimeoutGater],
                 gating_opts: [sleep_ms: 200],
                 gating_timeout_ms: 25,
                 policy_timeout_fallback: :deny
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 150
    end

    test "timeout fallback allow_with_flag keeps ingest hot path moving" do
      incoming = %{
        external_room_id: "chat_policy_timeout_allow",
        external_user_id: "user_policy_timeout_allow",
        text: "Timeout moderator",
        external_message_id: 6004
      }

      assert {:ok, message, _context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "policy_inst", incoming,
                 gaters: [AllowGater],
                 moderators: [TimeoutModerator],
                 moderation_opts: [sleep_ms: 200],
                 moderation_timeout_ms: 25,
                 policy_timeout_fallback: :allow_with_flag
               )

      assert is_map(message.metadata.policy)
      assert message.metadata.policy.flagged == true

      assert Enum.any?(message.metadata.policy.flags, fn flag ->
               flag.stage == :moderation and flag.reason == :policy_timeout
             end)
    end

    test "modified and flagged outcomes preserve metadata and emit policy telemetry" do
      test_pid = self()
      handler_id = "ingest-policy-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :ingest, :policy, :decision],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:policy_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      incoming = %{
        external_room_id: "chat_policy_metadata",
        external_user_id: "user_policy_metadata",
        text: "Bad content",
        external_message_id: 6005,
        timestamp: 1_706_745_601
      }

      assert {:ok, message, _context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "policy_inst", incoming,
                 gaters: [AllowGater],
                 moderators: [ModifyModerator, FlagModerator]
               )

      assert [%JidoMessaging.Content.Text{text: "[redacted]"}] = message.content
      assert message.metadata.external_message_id == 6005
      assert message.metadata.timestamp == 1_706_745_601
      assert message.metadata.moderation_note == "redacted"
      assert message.metadata.policy.modified == true
      assert message.metadata.policy.flagged == true

      assert Enum.any?(message.metadata.policy.flags, fn flag ->
               flag.reason == :unsafe_hint and flag.source == :moderation
             end)

      assert_receive {:policy_event, [:jido_messaging, :ingest, :policy, :decision], %{elapsed_ms: elapsed_ms},
                      %{stage: :moderation, policy_module: ModifyModerator, outcome: :modify}},
                     500

      assert elapsed_ms >= 0

      assert_receive {:policy_event, [:jido_messaging, :ingest, :policy, :decision], %{elapsed_ms: elapsed_ms},
                      %{stage: :moderation, policy_module: FlagModerator, outcome: :flag, reason: :unsafe_hint}},
                     500

      assert elapsed_ms >= 0
    end

    test "allowed messages with policy modules still persist and emit downstream signals" do
      test_pid = self()
      handler_id = "ingest-policy-happy-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:jido_messaging, :message, :received],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      incoming = %{
        external_room_id: "chat_policy_happy",
        external_user_id: "user_policy_happy",
        text: "Happy path",
        external_message_id: 6006
      }

      assert {:ok, message, context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "policy_inst", incoming,
                 gaters: [AllowGater],
                 moderators: [AllowModerator]
               )

      assert {:ok, [persisted]} = TestMessaging.list_messages(context.room.id)
      assert persisted.id == message.id

      message_id = message.id

      assert_receive {:telemetry_event, [:jido_messaging, :message, :received], _measurements,
                      %{instance_module: TestMessaging, message: %{id: ^message_id}}},
                     500
    end
  end

  describe "ingest_incoming/5 security boundary" do
    test "happy path verifies sender and persists security decision metadata" do
      incoming = %{
        external_room_id: "chat_security_happy",
        external_user_id: "user_security_happy",
        text: "Hello secure world",
        external_message_id: 7001,
        raw: %{claimed_sender_id: "user_security_happy"}
      }

      assert {:ok, message, _context} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "security_inst", incoming)

      assert is_map(message.metadata.security)
      assert message.metadata.security.verify.decision.stage == :verify
      assert message.metadata.security.verify.decision.classification == :allow
    end

    test "spoofed sender claim is denied with typed reason and no persistence occurs" do
      incoming = %{
        external_room_id: "chat_security_deny",
        external_user_id: "trusted_user",
        text: "spoof attempt",
        external_message_id: 7002,
        raw: %{claimed_sender_id: "spoofed_user"}
      }

      assert {:error, {:security_denied, :verify, :sender_claim_mismatch, _description}} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "security_inst", incoming)

      assert {:error, :not_found} =
               TestMessaging.get_room_by_external_binding(:mock, "security_inst", "chat_security_deny")

      assert {:error, :not_found} = TestMessaging.get_message_by_external_id(:mock, "security_inst", 7002)
    end

    test "security timeout policy deny is bounded and returns typed retry-class failure" do
      incoming = %{
        external_room_id: "chat_security_timeout_deny",
        external_user_id: "user_security_timeout_deny",
        text: "timeout deny",
        external_message_id: 7003
      }

      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:security_denied, :verify, {:security_failure, :retry}, _description}} =
               Ingest.ingest_incoming(TestMessaging, MockChannel, "security_inst", incoming,
                 security: [
                   adapter: SlowSecurityAdapter,
                   adapter_opts: [sleep_ms: 200],
                   verify_timeout_ms: 25,
                   verify_failure_policy: :deny
                 ]
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 150
    end
  end
end
