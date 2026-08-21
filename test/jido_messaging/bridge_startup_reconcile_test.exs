defmodule Jido.Messaging.BridgeStartupReconcileTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.{BridgeConfig, BridgeServer}
  alias Jido.Messaging.Persistence.SQLite

  defmodule StartupAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :startup_reconcile

    @impl true
    def transform_incoming(_payload), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:ok, %{message_id: "sent"}}
  end

  defmodule DependencyAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :startup_dependency

    @impl true
    def transform_incoming(_payload), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:ok, %{message_id: "sent"}}

    @impl true
    def listener_child_specs(_bridge_id, opts) do
      deduper = Module.concat(Keyword.fetch!(opts, :instance_module), Deduper)

      if Process.whereis(deduper) do
        {:ok, []}
      else
        {:error, :deduper_unavailable}
      end
    end
  end

  defmodule FailingAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :startup_failure

    @impl true
    def transform_incoming(_payload), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:ok, %{message_id: "sent"}}

    @impl true
    def listener_child_specs(_bridge_id, _opts), do: {:error, :listener_failed}
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  describe "startup reconciliation" do
    test "starts enabled bridge workers from persisted configuration" do
      database_path = tmp_path("startup")
      on_exit(fn -> File.rm(database_path) end)

      {:ok, first_supervisor} = SQLiteMessaging.start_link(persistence_opts: [path: database_path])

      assert {:ok, _bridge} =
               SQLiteMessaging.put_bridge_config(%{
                 id: "persisted_bridge",
                 adapter_module: StartupAdapter,
                 enabled: true
               })

      assert_eventually(fn -> is_pid(BridgeServer.whereis(SQLiteMessaging, "persisted_bridge")) end)

      Supervisor.stop(first_supervisor)

      {:ok, second_supervisor} = SQLiteMessaging.start_link(persistence_opts: [path: database_path])
      on_exit(fn -> stop_supervisor(second_supervisor) end)

      assert_eventually(fn -> is_pid(BridgeServer.whereis(SQLiteMessaging, "persisted_bridge")) end)
      assert {:ok, status} = SQLiteMessaging.bridge_status("persisted_bridge")
      assert status.enabled
    end

    test "does not start disabled persisted bridges" do
      database_path = tmp_path("disabled")
      on_exit(fn -> File.rm(database_path) end)

      {:ok, first_supervisor} = SQLiteMessaging.start_link(persistence_opts: [path: database_path])

      assert {:ok, _bridge} =
               SQLiteMessaging.put_bridge_config(%{
                 id: "disabled_bridge",
                 adapter_module: StartupAdapter,
                 enabled: false
               })

      Supervisor.stop(first_supervisor)
      {:ok, second_supervisor} = SQLiteMessaging.start_link(persistence_opts: [path: database_path])
      on_exit(fn -> stop_supervisor(second_supervisor) end)

      refute BridgeServer.whereis(SQLiteMessaging, "disabled_bridge")
      assert SQLiteMessaging.list_bridges() == []
    end

    test "starts bridge listeners only after the deduper is available" do
      database_path = tmp_path("dependency_order")
      on_exit(fn -> File.rm(database_path) end)
      persist_bridge(database_path, "dependency_bridge", DependencyAdapter)

      assert {:ok, supervisor} = SQLiteMessaging.start_link(persistence_opts: [path: database_path])
      on_exit(fn -> stop_supervisor(supervisor) end)

      assert is_pid(BridgeServer.whereis(SQLiteMessaging, "dependency_bridge"))
    end

    test "fails startup when a persisted enabled bridge cannot start" do
      database_path = tmp_path("failed_bridge")
      on_exit(fn -> File.rm(database_path) end)
      persist_bridge(database_path, "failed_bridge", FailingAdapter)

      previous_trap_exit = Process.flag(:trap_exit, true)
      assert {:error, reason} = SQLiteMessaging.start_link(persistence_opts: [path: database_path])
      Process.flag(:trap_exit, previous_trap_exit)

      assert inspect(reason) =~ "listener_failed"
      refute Process.whereis(Module.concat(SQLiteMessaging, :BridgeSupervisor))
    end
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp stop_supervisor(supervisor) do
    if Process.alive?(supervisor) do
      Supervisor.stop(supervisor)
    end
  catch
    :exit, _reason -> :ok
  end

  defp persist_bridge(database_path, bridge_id, adapter_module) do
    {:ok, state} = SQLite.init(path: database_path)
    config = BridgeConfig.new(%{id: bridge_id, adapter_module: adapter_module, enabled: true})
    assert {:ok, ^config} = SQLite.save_bridge_config(state, config)
    :ok = Exqlite.Sqlite3.close(state.db)
  end

  defp tmp_path(label) do
    Path.join(System.tmp_dir!(), "jido_messaging_#{label}_#{System.unique_integer([:positive])}.db")
  end
end
