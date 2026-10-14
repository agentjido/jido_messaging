defmodule Jido.Messaging.PresenceTrackerTest do
  use ExUnit.Case, async: false
  import Jido.Messaging.TestHelpers

  defmodule Runtime do
    use Jido.Messaging, runtime_profile: :core
  end

  defmodule Tracker do
    use Phoenix.Tracker

    def start_link(opts),
      do: Phoenix.Tracker.start_link(__MODULE__, opts, Keyword.put(opts, :name, __MODULE__))

    def init(opts), do: {:ok, opts}
    def handle_diff(_diff, state), do: {:ok, state}
  end

  defmodule RealPresence do
    def fail_next_track(reason), do: Agent.update(__MODULE__, &Map.put(&1, :track, reason))
    def fail_next_untrack(reason), do: Agent.update(__MODULE__, &Map.put(&1, :untrack, reason))

    def track(pid, topic, key, meta) do
      case Agent.get_and_update(__MODULE__, &Map.pop(&1, :track)) do
        nil -> Phoenix.Tracker.track(Tracker, pid, topic, key, meta)
        reason -> {:error, reason}
      end
    end

    def update(pid, topic, key, meta), do: Phoenix.Tracker.update(Tracker, pid, topic, key, meta)

    def untrack(pid, topic, key) do
      case Agent.get_and_update(__MODULE__, &Map.pop(&1, :untrack)) do
        nil -> Phoenix.Tracker.untrack(Tracker, pid, topic, key)
        reason -> {:error, reason}
      end
    end
  end

  defmodule Adapter do
    use Jido.Messaging.Presence,
      messaging: Runtime,
      presence: RealPresence,
      topic: "tracker-test",
      ttl_ms: 60_000,
      prune_ms: 60_000
  end

  setup do
    start_supervised!(Runtime)
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})

    start_supervised!(%{
      id: Tracker,
      start: {Tracker, :start_link, [[pubsub_server: __MODULE__.PubSub]]}
    })

    start_supervised!(%{
      id: RealPresence,
      start: {Agent, :start_link, [fn -> %{} end, [name: RealPresence]]}
    })

    start_supervised!(Adapter)

    old =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    replacement =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      send(old, :stop)
      send(replacement, :stop)
    end)

    {:ok, old: old, replacement: replacement}
  end

  test "PID replacement moves a session without new occupancy facts", %{
    old: old,
    replacement: replacement
  } do
    assert {:ok, %{online_user_ids: ["user"]}, joined} = touch(old)
    assert length(joined) == 2
    assert {:ok, %{online_user_ids: ["user"]}, []} = touch(old)
    assert {:ok, %{online_user_ids: ["user"]}, []} = touch(replacement)
    assert targets() == [replacement]
    assert {:ok, %{online_user_ids: []}, left} = Adapter.mark_left("user", session_id: "session")
    assert length(left) == 2
    assert targets() == []
  end

  test "failed replacement attachment preserves the old target and local state", %{
    old: old,
    replacement: replacement
  } do
    assert {:ok, _, _} = touch(old)
    before = :sys.get_state(Adapter)
    RealPresence.fail_next_track(:attachment_failed)
    assert {:error, :attachment_failed} = touch(replacement)
    assert :sys.get_state(Adapter) == before
    assert targets() == [old]
    assert {:ok, _, []} = touch(replacement)
    assert targets() == [replacement]
  end

  test "replacement after old target death and TTL prune cleans tracking", %{
    old: old,
    replacement: replacement
  } do
    assert {:ok, _, _} = touch(old)
    monitor = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old, :killed}
    assert_eventually(fn -> targets() == [] end)
    assert {:ok, _, []} = touch(replacement)
    assert targets() == [replacement]

    :sys.replace_state(Adapter, fn state ->
      put_in(
        state,
        [:participants, "user", :sessions, "session", :expires_at],
        System.system_time(:millisecond) - 1
      )
    end)

    send(Adapter, :prune)
    assert Adapter.snapshot() == %{online_user_ids: []}
    assert targets() == []
  end

  test "failed old-target detach rolls back the replacement", %{
    old: old,
    replacement: replacement
  } do
    assert {:ok, _, _} = touch(old)
    before = :sys.get_state(Adapter)
    RealPresence.fail_next_untrack(:detach_failed)
    assert {:error, :detach_failed} = touch(replacement)
    assert :sys.get_state(Adapter) == before
    assert targets() == [old]
  end

  test "a missing same-PID tracking row is attached without new occupancy facts", %{old: old} do
    assert {:ok, _, _} = touch(old)
    :ok = Phoenix.Tracker.untrack(Tracker, old, "tracker-test", "session")
    assert {:ok, _, []} = touch(old)
    assert targets() == [old]
  end

  defp touch(pid), do: Adapter.touch("user", "room", session_id: "session", track_pid: pid)

  defp targets,
    do:
      Phoenix.Tracker.get_by_key(Tracker, "tracker-test", "session")
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
end
