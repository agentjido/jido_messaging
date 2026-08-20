defmodule Jido.Messaging.BridgeStartupReconcileTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.BridgeServer

  defmodule StartupAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :startup_reconcile

    @impl true
    def transform_incoming(_payload), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:ok, %{message_id: "sent"}}
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  test "starts enabled bridge workers from persisted configuration" do
    database_path = Path.join(System.tmp_dir!(), "jido_messaging_startup_#{System.unique_integer([:positive])}.db")
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
    database_path = Path.join(System.tmp_dir!(), "jido_messaging_disabled_#{System.unique_integer([:positive])}.db")
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
end
