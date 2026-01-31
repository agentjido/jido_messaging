defmodule JidoMessaging.TestHelpers do
  @moduledoc """
  Shared test helpers for JidoMessaging tests.
  """

  import ExUnit.Assertions

  @doc """
  Asserts that a condition becomes true within a timeout.

  This is preferred over `Process.sleep` as it will return as soon as
  the condition is met, making tests faster and less flaky.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 100)
  - `:interval` - Time between checks in milliseconds (default: 5)

  ## Examples

      assert_eventually(fn -> GenServer.call(pid, :ready) end)

      assert_eventually(fn ->
        state = get_state(pid)
        state.count > 5
      end, timeout: 500)
  """
  def assert_eventually(func, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 100)
    interval = Keyword.get(opts, :interval, 5)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_assert_eventually(func, deadline, interval)
  end

  defp do_assert_eventually(func, deadline, interval) do
    if func.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("Condition was not met within timeout")
      else
        Process.sleep(interval)
        do_assert_eventually(func, deadline, interval)
      end
    end
  end

  @doc """
  Waits for a process to terminate.

  Uses process monitoring instead of polling, which is more reliable.
  """
  def await_termination(pid, timeout \\ 100) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        flunk("Process did not terminate within #{timeout}ms")
    end
  end
end
