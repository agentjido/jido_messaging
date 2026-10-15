defmodule Jido.Messaging.StreamingTest do
  use ExUnit.Case, async: true

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.Streaming

  defmodule MockChannel do
    @moduledoc false

    def send_message(_chat_id, _text, _opts) do
      {:ok, %{message_id: 123, chat_id: 456, date: 1_234_567_890}}
    end

    def edit_message(_chat_id, _message_id, _text) do
      {:ok, %{message_id: 123, chat_id: 456, date: 1_234_567_890}}
    end
  end

  defmodule FailingChannel do
    @moduledoc false

    def send_message(_chat_id, _text, _opts) do
      {:error, :network_error}
    end
  end

  defmodule NoEditChannel do
    @moduledoc false

    def send_message(_chat_id, _text, _opts) do
      {:ok, %{message_id: 123, chat_id: 456, date: 1_234_567_890}}
    end
  end

  defmodule FailingEditChannel do
    @moduledoc false

    def send_message(_chat_id, _text, _opts) do
      {:ok, %{message_id: 123, chat_id: 456, date: 1_234_567_890}}
    end

    def edit_message(_chat_id, _message_id, _text) do
      {:error, :edit_failed}
    end
  end

  defmodule RecordingChannel do
    def send_message(owner, _text, _opts), do: {:ok, %{message_id: owner}}

    def edit_message(owner, _message_id, text) do
      send(owner, {:stream_edit, text})
      {:ok, %{}}
    end
  end

  describe "start/6" do
    test "starts a stream with initial content" do
      {:ok, stream} = Streaming.start(nil, nil, MockChannel, 123, "Hello...")

      state = Streaming.get_state(stream)

      assert state.message_id == 123
      assert state.current_content == "Hello..."
      assert state.chat_id == 123
    end

    test "returns error when initial send fails" do
      result = Streaming.start(nil, nil, FailingChannel, 123, "Hello...")

      assert {:error, {:send_failed, :network_error}} = result
    end
  end

  describe "update/2" do
    test "a stale flush cannot send content from a newer throttle window" do
      {:ok, stream} =
        Streaming.start(nil, nil, RecordingChannel, self(), "initial", min_update_interval_ms: 60_000)

      on_exit(fn -> if Process.alive?(stream), do: Streaming.cancel(stream) end)
      :ok = Streaming.update(stream, "older")
      state = Streaming.get_state(stream)

      old_flush =
        case Map.get(state, :pending_timer) do
          {_timer, token} -> {:flush_pending, token}
          nil -> :flush_pending
        end

      :sys.replace_state(stream, fn current ->
        %{current | last_update_at: System.monotonic_time(:millisecond) - 60_000}
      end)

      :ok = :sys.suspend(stream)
      :ok = Streaming.update(stream, "immediate")
      :ok = Streaming.update(stream, "next window")
      send(stream, old_flush)
      :ok = :sys.resume(stream)

      assert %{current_content: "immediate", pending_update: "next window"} =
               Streaming.get_state(stream)

      assert_receive {:stream_edit, "immediate"}
      refute_receive {:stream_edit, "next window"}, 0
    end

    test "a newer immediate update clears an older pending edit" do
      {:ok, stream} =
        Streaming.start(nil, nil, RecordingChannel, self(), "initial", min_update_interval_ms: 60_000)

      on_exit(fn -> if Process.alive?(stream), do: Streaming.cancel(stream) end)

      :ok = Streaming.update(stream, "older")
      assert %{pending_update: "older"} = Streaming.get_state(stream)

      :sys.replace_state(stream, fn state ->
        %{state | last_update_at: System.monotonic_time(:millisecond) - 60_000}
      end)

      :ok = :sys.suspend(stream)
      :ok = Streaming.update(stream, "newer")
      send(stream, :flush_pending)
      :ok = :sys.resume(stream)

      assert %{current_content: "newer", pending_update: nil} = Streaming.get_state(stream)
      assert_receive {:stream_edit, "newer"}
      refute_receive {:stream_edit, "older"}, 0
    end

    test "updates stream content" do
      {:ok, stream} =
        Streaming.start(nil, nil, MockChannel, 123, "Hello...", min_update_interval_ms: 0)

      :ok = Streaming.update(stream, "Hello... World!")

      assert_eventually(fn ->
        state = Streaming.get_state(stream)
        state.current_content == "Hello... World!"
      end)
    end

    test "throttles rapid updates" do
      {:ok, stream} =
        Streaming.start(nil, nil, MockChannel, 123, "Hello...", min_update_interval_ms: 500)

      Streaming.update(stream, "Update 1")
      Streaming.update(stream, "Update 2")
      Streaming.update(stream, "Update 3")

      state = Streaming.get_state(stream)
      assert state.pending_update == "Update 3"
    end

    test "flushes pending update after interval" do
      {:ok, stream} =
        Streaming.start(nil, nil, MockChannel, 123, "Hello...", min_update_interval_ms: 10)

      Streaming.update(stream, "Pending update")

      assert_eventually(fn ->
        state = Streaming.get_state(stream)
        state.current_content == "Pending update" and state.pending_update == nil
      end)
    end
  end

  describe "finish/2" do
    test "returns the final provider error and stops the stream" do
      {:ok, stream} = Streaming.start(nil, nil, FailingEditChannel, 123, "initial")
      monitor = Process.monitor(stream)

      assert {:error, :edit_failed} = Streaming.finish(stream, "final")
      assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}
    end

    test "finalizes stream with content" do
      {:ok, stream} = Streaming.start(nil, nil, MockChannel, 123, "Hello...")

      {:ok, result} = Streaming.finish(stream, "Final content")

      assert result.message_id == 123
      assert result.content == "Final content"

      refute Process.alive?(stream)
    end
  end

  describe "cancel/1" do
    test "stops the stream process" do
      {:ok, stream} = Streaming.start(nil, nil, MockChannel, 123, "Hello...")
      ref = Process.monitor(stream)

      Streaming.cancel(stream)

      assert_receive {:DOWN, ^ref, :process, ^stream, :normal}, 100
    end
  end

  describe "channel without edit_message" do
    test "handles channels that don't support edit_message" do
      {:ok, stream} =
        Streaming.start(nil, nil, NoEditChannel, 123, "Hello...", min_update_interval_ms: 0)

      :ok = Streaming.update(stream, "Updated content")

      assert_eventually(fn ->
        state = Streaming.get_state(stream)
        state.current_content == "Updated content"
      end)
    end
  end

  describe "duplicate content" do
    test "skips update when content unchanged" do
      {:ok, stream} =
        Streaming.start(nil, nil, MockChannel, 123, "Same content", min_update_interval_ms: 0)

      initial_state = Streaming.get_state(stream)
      initial_update_time = initial_state.last_update_at

      Streaming.update(stream, "Same content")

      assert_eventually(fn ->
        state = Streaming.get_state(stream)
        state.last_update_at == initial_update_time
      end)
    end
  end

  describe "edit failures" do
    test "handles edit_message failures gracefully" do
      {:ok, stream} =
        Streaming.start(nil, nil, FailingEditChannel, 123, "Hello...", min_update_interval_ms: 0)

      :ok = Streaming.update(stream, "Will fail to edit")

      assert_eventually(fn ->
        state = Streaming.get_state(stream)
        state.current_content == "Hello..."
      end)
    end
  end

  describe "flush_pending with nil" do
    test "handles flush_pending when no pending update" do
      {:ok, stream} =
        Streaming.start(nil, nil, MockChannel, 123, "Hello...", min_update_interval_ms: 100)

      send(stream, :flush_pending)

      state = Streaming.get_state(stream)
      assert state.current_content == "Hello..."
      assert state.pending_update == nil
    end
  end
end
