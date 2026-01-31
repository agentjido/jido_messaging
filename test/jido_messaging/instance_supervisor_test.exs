defmodule JidoMessaging.InstanceSupervisorTest do
  use ExUnit.Case, async: true

  import JidoMessaging.TestHelpers

  alias JidoMessaging.{InstanceSupervisor, InstanceServer}

  defmodule TestMessaging do
    use JidoMessaging,
      adapter: JidoMessaging.Adapters.ETS
  end

  setup do
    start_supervised!(TestMessaging)
    :ok
  end

  describe "start_instance/3" do
    test "starts a new instance and returns instance struct" do
      {:ok, instance} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "My Bot"})

      assert instance.id != nil
      assert instance.channel_type == :telegram
      assert instance.name == "My Bot"
      assert instance.status == :starting
    end

    test "instance is registered and accessible via InstanceServer" do
      {:ok, instance} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "Bot 1"})

      pid = InstanceServer.whereis(TestMessaging, instance.id)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "multiple instances can be started" do
      {:ok, inst1} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "Bot 1"})
      {:ok, inst2} = InstanceSupervisor.start_instance(TestMessaging, :discord, %{name: "Bot 2"})

      assert inst1.id != inst2.id
      assert InstanceServer.whereis(TestMessaging, inst1.id) != nil
      assert InstanceServer.whereis(TestMessaging, inst2.id) != nil
    end
  end

  describe "stop_instance/2" do
    test "stops a running instance" do
      {:ok, instance} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "Bot"})

      pid = InstanceServer.whereis(TestMessaging, instance.id)
      assert Process.alive?(pid)

      ref = Process.monitor(pid)
      assert :ok = InstanceSupervisor.stop_instance(TestMessaging, instance.id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

      # Registry cleanup may lag slightly behind process termination
      assert_eventually(fn -> InstanceServer.whereis(TestMessaging, instance.id) == nil end)
    end

    test "returns error for non-existent instance" do
      assert {:error, :not_found} = InstanceSupervisor.stop_instance(TestMessaging, "nonexistent")
    end
  end

  describe "instance_status/2" do
    test "returns status for running instance" do
      {:ok, instance} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "Status Bot"})

      {:ok, status} = InstanceSupervisor.instance_status(TestMessaging, instance.id)

      assert status.status == :starting
      assert status.instance_id == instance.id
    end

    test "returns error for non-existent instance" do
      assert {:error, :not_found} = InstanceSupervisor.instance_status(TestMessaging, "missing")
    end
  end

  describe "list_instances/1" do
    test "returns empty list when no instances" do
      instances = InstanceSupervisor.list_instances(TestMessaging)
      assert instances == []
    end

    test "returns all running instances" do
      {:ok, _} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "Bot A"})
      {:ok, _} = InstanceSupervisor.start_instance(TestMessaging, :discord, %{name: "Bot B"})

      instances = InstanceSupervisor.list_instances(TestMessaging)
      assert length(instances) == 2

      names = Enum.map(instances, & &1.name)
      assert "Bot A" in names
      assert "Bot B" in names
    end
  end

  describe "count_instances/1" do
    test "returns 0 when no instances" do
      assert InstanceSupervisor.count_instances(TestMessaging) == 0
    end

    test "returns correct count" do
      {:ok, _} = InstanceSupervisor.start_instance(TestMessaging, :telegram, %{name: "Bot 1"})
      assert InstanceSupervisor.count_instances(TestMessaging) == 1

      {:ok, _} = InstanceSupervisor.start_instance(TestMessaging, :discord, %{name: "Bot 2"})
      assert InstanceSupervisor.count_instances(TestMessaging) == 2
    end
  end

  describe "messaging module API" do
    test "start_instance is accessible from messaging module" do
      {:ok, instance} = TestMessaging.start_instance(:telegram, %{name: "API Bot"})
      assert instance.channel_type == :telegram
    end

    test "stop_instance is accessible from messaging module" do
      {:ok, instance} = TestMessaging.start_instance(:telegram, %{name: "Stop Bot"})
      assert :ok = TestMessaging.stop_instance(instance.id)
    end

    test "instance_status is accessible from messaging module" do
      {:ok, instance} = TestMessaging.start_instance(:telegram, %{name: "Status Bot"})
      {:ok, status} = TestMessaging.instance_status(instance.id)
      assert status.status == :starting
    end

    test "list_instances is accessible from messaging module" do
      {:ok, _} = TestMessaging.start_instance(:telegram, %{name: "List Bot"})
      instances = TestMessaging.list_instances()
      assert length(instances) == 1
    end

    test "count_instances is accessible from messaging module" do
      initial = TestMessaging.count_instances()
      {:ok, _} = TestMessaging.start_instance(:telegram, %{name: "Count Bot"})
      assert TestMessaging.count_instances() == initial + 1
    end
  end
end
