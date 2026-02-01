defmodule JidoMessaging.HealthTest do
  use ExUnit.Case, async: true

  import JidoMessaging.TestHelpers

  alias JidoMessaging.{Instance, InstanceServer, InstanceSupervisor}

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  defp create_instance(attrs \\ %{}) do
    attrs
    |> Map.put_new(:channel_type, :telegram)
    |> Map.put_new(:name, "Test Bot")
    |> Instance.new()
  end

  describe "health_snapshot/1" do
    test "returns correct structure with all required fields" do
      instance = create_instance()

      {:ok, pid} =
        InstanceServer.start_link(
          instance_module: TestMessaging,
          instance: instance
        )

      {:ok, snapshot} = InstanceServer.health_snapshot(pid)

      assert Map.has_key?(snapshot, :status)
      assert Map.has_key?(snapshot, :instance_id)
      assert Map.has_key?(snapshot, :channel_type)
      assert Map.has_key?(snapshot, :name)
      assert Map.has_key?(snapshot, :uptime_ms)
      assert Map.has_key?(snapshot, :connected_at)
      assert Map.has_key?(snapshot, :last_error)
      assert Map.has_key?(snapshot, :consecutive_failures)
      assert Map.has_key?(snapshot, :sender_queue_depth)

      assert snapshot.status == :starting
      assert snapshot.instance_id == instance.id
      assert snapshot.channel_type == :telegram
      assert snapshot.name == "Test Bot"
      assert snapshot.connected_at == nil
      assert snapshot.last_error == nil
      assert snapshot.consecutive_failures == 0
      assert snapshot.sender_queue_depth == 0
    end

    test "uptime_ms is calculated correctly" do
      instance = create_instance()

      {:ok, pid} =
        InstanceServer.start_link(
          instance_module: TestMessaging,
          instance: instance
        )

      {:ok, snapshot1} = InstanceServer.health_snapshot(pid)
      uptime1 = snapshot1.uptime_ms

      Process.sleep(50)

      {:ok, snapshot2} = InstanceServer.health_snapshot(pid)
      uptime2 = snapshot2.uptime_ms

      assert uptime2 > uptime1
      assert uptime2 >= 50
    end

    test "uptime_ms is non-negative" do
      instance = create_instance()

      {:ok, pid} =
        InstanceServer.start_link(
          instance_module: TestMessaging,
          instance: instance
        )

      {:ok, snapshot} = InstanceServer.health_snapshot(pid)
      assert snapshot.uptime_ms >= 0
    end

    test "reflects connected_at when connected" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      InstanceServer.notify_connected(pid)

      assert_eventually(fn ->
        {:ok, snapshot} = InstanceServer.health_snapshot(pid)
        snapshot.status == :connected and snapshot.connected_at != nil
      end)

      {:ok, snapshot} = InstanceServer.health_snapshot(pid)
      assert %DateTime{} = snapshot.connected_at
    end

    test "reflects last_error and consecutive_failures" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      for _ <- 1..3 do
        InstanceServer.notify_failure(pid, :test_error)
      end

      assert_eventually(fn ->
        {:ok, snapshot} = InstanceServer.health_snapshot(pid)
        snapshot.consecutive_failures == 3
      end)

      {:ok, snapshot} = InstanceServer.health_snapshot(pid)
      assert snapshot.last_error == :test_error
      assert snapshot.consecutive_failures == 3
    end
  end

  describe "instance_health/1 via messaging module" do
    test "returns health snapshot for existing instance" do
      {:ok, instance} = TestMessaging.start_instance(:telegram, %{name: "Health Test Bot"})

      {:ok, snapshot} = TestMessaging.instance_health(instance.id)

      assert snapshot.instance_id == instance.id
      assert snapshot.channel_type == :telegram
      assert snapshot.name == "Health Test Bot"
      assert is_integer(snapshot.uptime_ms)
    end

    test "returns error for non-existent instance" do
      assert {:error, :not_found} = TestMessaging.instance_health("nonexistent")
    end
  end

  describe "list_instance_health/1" do
    test "returns empty list when no instances" do
      assert TestMessaging.list_instance_health() == []
    end

    test "returns health for all running instances" do
      {:ok, instance1} = TestMessaging.start_instance(:telegram, %{name: "Bot 1"})
      {:ok, instance2} = TestMessaging.start_instance(:discord, %{name: "Bot 2"})

      health_list = TestMessaging.list_instance_health()

      assert length(health_list) == 2

      ids = Enum.map(health_list, & &1.instance_id)
      assert instance1.id in ids
      assert instance2.id in ids

      names = Enum.map(health_list, & &1.name)
      assert "Bot 1" in names
      assert "Bot 2" in names
    end

    test "each health snapshot has correct structure" do
      {:ok, _} = TestMessaging.start_instance(:telegram, %{name: "Test Bot"})

      [snapshot] = TestMessaging.list_instance_health()

      assert Map.has_key?(snapshot, :status)
      assert Map.has_key?(snapshot, :instance_id)
      assert Map.has_key?(snapshot, :channel_type)
      assert Map.has_key?(snapshot, :name)
      assert Map.has_key?(snapshot, :uptime_ms)
      assert Map.has_key?(snapshot, :connected_at)
      assert Map.has_key?(snapshot, :last_error)
      assert Map.has_key?(snapshot, :consecutive_failures)
      assert Map.has_key?(snapshot, :sender_queue_depth)
    end
  end

  describe "list_instance_health/1 via InstanceSupervisor" do
    test "returns health for all instances" do
      {:ok, instance1} = TestMessaging.start_instance(:telegram, %{name: "Supervisor Bot 1"})
      {:ok, instance2} = TestMessaging.start_instance(:slack, %{name: "Supervisor Bot 2"})

      health_list = InstanceSupervisor.list_instance_health(TestMessaging)

      assert length(health_list) == 2

      ids = Enum.map(health_list, & &1.instance_id)
      assert instance1.id in ids
      assert instance2.id in ids
    end
  end
end
