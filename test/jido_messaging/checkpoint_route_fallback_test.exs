defmodule Jido.Messaging.CheckpointRouteFallbackTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{SessionManager}

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    previous = Application.fetch_env(Instance, :session_manager)

    Application.put_env(Instance, :session_manager,
      partition_count: 1,
      ttl_ms: 60_000,
      max_entries_per_partition: 3,
      prune_interval_ms: 60_000
    )

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(Instance, :session_manager, config)
        :error -> Application.delete_env(Instance, :session_manager)
      end
    end)

    start_supervised!(Instance)
    {:ok, pid: SessionManager.partition_pid(Instance, 0)}
  end

  defp key(thread), do: {:test, "bridge", "room", thread}
  defp route(id), do: %{external_room_id: id, room_id: "room", bridge_id: "bridge"}

  defp expire(pid, session_key) do
    :sys.replace_state(pid, fn state ->
      [{^session_key, entry}] = :ets.lookup(state.table, session_key)
      true = :ets.insert(state.table, {session_key, %{entry | expires_at_ms: System.monotonic_time(:millisecond) - 1}})
      state
    end)
  end

  test "thread lookup keeps the room route, repairs an expired thread and preserves other rooms", %{pid: pid} do
    room_route = route("provider-room")
    assert :ok = SessionManager.set(Instance, key(nil), room_route)
    assert :ok = SessionManager.set(Instance, {:test, "bridge", "foreign", nil}, route("foreign"))

    assert {:ok, %{source: :partition_fallback, fallback_reason: :thread_scope_miss, stale: false, route: ^room_route}} =
             SessionManager.resolve(Instance, key("thread"))

    expire(pid, key("thread"))

    assert {:ok, %{source: :partition_fallback, fallback_reason: :stale, stale: true, route: ^room_route}} =
             SessionManager.resolve(Instance, key("thread"))

    assert {:ok, %{route: ^room_route}} = SessionManager.get(Instance, key("thread"))

    assert {:ok, %{route: %{external_room_id: "foreign"}}} =
             SessionManager.get(Instance, {:test, "bridge", "foreign", nil})
  end

  test "expired room and thread resolve one supplied route and then use the cached result", %{pid: pid} do
    :ok = SessionManager.set(Instance, key(nil), route("old-room"))
    :ok = SessionManager.set(Instance, key("thread"), route("old-thread"))
    expire(pid, key(nil))
    expire(pid, key("thread"))
    replacement = route("complete-replacement")

    assert {:ok, %{source: :provided_fallback, fallback_reason: :stale, stale: true, route: ^replacement}} =
             SessionManager.resolve(Instance, key("thread"), [replacement])

    assert {:ok, %{source: :state_hit, stale: false, route: ^replacement}} =
             SessionManager.resolve(Instance, key("thread"))

    assert Jido.Messaging.TestHelpers.runtime_entry_count(Instance.__jido_messaging__(:runtime)) == 0
  end

  test "periodic pruning removes expired state and retains fresh state", %{pid: pid} do
    :ok = SessionManager.set(Instance, key("expired"), route("expired"))
    :ok = SessionManager.set(Instance, key("fresh"), route("fresh"))
    expire(pid, key("expired"))
    send(pid, :prune_tick)
    _ = :sys.get_state(pid)
    assert {:error, :not_found} = SessionManager.get(Instance, key("expired"))
    assert {:ok, %{route: %{external_room_id: "fresh"}}} = SessionManager.get(Instance, key("fresh"))
    assert %{pruned: 0, partitions: 1} = SessionManager.prune(Instance)
  end

  test "an unavailable partition uses only a valid supplied fallback", %{pid: pid} do
    supervisor = Module.concat(Instance, :SessionManagerSupervisor)
    {id, ^pid, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, child, _, _} -> child == pid end)
    :ok = Supervisor.terminate_child(supervisor, id)
    assert {:error, :partition_unavailable} = SessionManager.resolve(Instance, key("thread"))

    assert {:ok, %{source: :provided_fallback, fallback_reason: :session_unavailable, external_room_id: "provided"}} =
             SessionManager.resolve(Instance, key("thread"), route("provided"))

    assert %{pruned: 0, partitions: 1} = SessionManager.prune(Instance)
  end

  test "a stopped partition still in the registry returns errors and uses valid supplied fallbacks", %{pid: pid} do
    registry = Module.concat(Instance, Registry.Instances)
    [{_, registry_pid, _, _}] = Supervisor.which_children(registry)
    :ok = :sys.suspend(registry_pid)

    try do
      supervisor = Module.concat(Instance, :SessionManagerSupervisor)
      :ok = Supervisor.terminate_child(supervisor, {:session_manager_partition, 0})
      refute Process.alive?(pid)
      assert SessionManager.partition_pid(Instance, 0) == pid

      assert {:error, :partition_unavailable} = SessionManager.set(Instance, key("thread"), route("unused"))
      assert {:error, :partition_unavailable} = SessionManager.get(Instance, key("thread"))
      assert {:error, :partition_unavailable} = SessionManager.resolve(Instance, key("thread"), [%{}, nil])
      assert %{pruned: 0, partitions: 1} = SessionManager.prune(Instance)

      assert {:ok, %{source: :provided_fallback, fallback_reason: :session_unavailable, external_room_id: "provided"}} =
               SessionManager.resolve(Instance, key("thread"), [%{}, route("provided")])
    after
      :ok = :sys.resume(registry_pid)
    end
  end
end
