defmodule Jido.Messaging.AuditLoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Messaging.AuditLogger

  setup do
    on_exit(fn ->
      AuditLogger.detach()
    end)

    :ok
  end

  describe "attach/1" do
    test "attaches to telemetry events" do
      assert :ok = AuditLogger.attach()
    end

    test "returns error when already attached" do
      :ok = AuditLogger.attach()
      assert {:error, :already_exists} = AuditLogger.attach()
    end
  end

  describe "detach/0" do
    test "detaches from telemetry events" do
      :ok = AuditLogger.attach()
      assert :ok = AuditLogger.detach()
    end

    test "returns error when not attached" do
      assert {:error, :not_found} = AuditLogger.detach()
    end
  end

  describe "handle_event/4" do
    test "logs message received events" do
      :ok = AuditLogger.attach(log_level: :info)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:jido_messaging, :message, :received],
            %{timestamp: DateTime.utc_now()},
            %{
              message: %{id: "msg_123"},
              room_id: "room_456",
              participant_id: "user_789",
              correlation_id: "corr_abc"
            }
          )
        end)

      assert log =~ "message.received"
      assert log =~ "room_456"
      assert log =~ "user_789"
    end

    test "logs presence changed events" do
      :ok = AuditLogger.attach(log_level: :info)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:jido_messaging, :participant, :presence_changed],
            %{timestamp: DateTime.utc_now()},
            %{
              room_id: "room_123",
              participant_id: "user_456",
              from: :offline,
              to: :online,
              correlation_id: "corr_xyz"
            }
          )
        end)

      assert log =~ "presence_changed"
      assert log =~ "offline"
      assert log =~ "online"
    end

    test "logs reaction events" do
      :ok = AuditLogger.attach(log_level: :info)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:jido_messaging, :message, :reaction_added],
            %{timestamp: DateTime.utc_now()},
            %{
              room_id: "room_123",
              message_id: "msg_456",
              participant_id: "user_789",
              reaction: "👍",
              correlation_id: "corr_123"
            }
          )
        end)

      assert log =~ "reaction_added"
      assert log =~ "👍"
    end

    test "logs thread events" do
      :ok = AuditLogger.attach(log_level: :info)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:jido_messaging, :thread, :created],
            %{timestamp: DateTime.utc_now()},
            %{
              room_id: "room_123",
              root_message_id: "msg_456",
              correlation_id: "corr_abc"
            }
          )
        end)

      assert log =~ "thread.created"
      assert log =~ "msg_456"
    end

    test "does not log typing events by default" do
      :ok = AuditLogger.attach(log_level: :info, include_typing: false)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:jido_messaging, :participant, :typing],
            %{timestamp: DateTime.utc_now()},
            %{
              room_id: "room_123",
              participant_id: "user_456",
              is_typing: true,
              thread_root_id: nil,
              correlation_id: "corr_xyz"
            }
          )
        end)

      assert log == ""
    end

    test "logs typing events when enabled" do
      :ok = AuditLogger.attach(log_level: :info, include_typing: true)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:jido_messaging, :participant, :typing],
            %{timestamp: DateTime.utc_now()},
            %{
              room_id: "room_123",
              participant_id: "user_456",
              is_typing: true,
              thread_root_id: nil,
              correlation_id: "corr_xyz"
            }
          )
        end)

      assert log =~ "typing"
      assert log =~ "started"
    end
  end
end
