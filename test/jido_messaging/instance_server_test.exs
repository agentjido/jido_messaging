defmodule Jido.Messaging.InstanceServerTest do
  use ExUnit.Case, async: true

  import Jido.Messaging.TestHelpers

  alias Jido.Messaging.{Instance, InstanceServer}

  defmodule TestMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
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

  describe "start_link/1" do
    test "starts instance server with initial :starting status" do
      instance = create_instance()

      {:ok, pid} =
        InstanceServer.start_link(
          instance_module: TestMessaging,
          instance: instance
        )

      assert {:ok, status} = InstanceServer.status(pid)
      assert status.status == :starting
      assert status.instance_id == instance.id
      assert status.channel_type == :telegram
    end
  end

  describe "whereis/2" do
    test "finds running instance server" do
      instance = create_instance()

      {:ok, pid} =
        InstanceServer.start_link(
          instance_module: TestMessaging,
          instance: instance
        )

      assert InstanceServer.whereis(TestMessaging, instance.id) == pid
    end

    test "returns nil for non-existent instance" do
      assert InstanceServer.whereis(TestMessaging, "nonexistent") == nil
    end
  end

  describe "status/1" do
    test "returns current instance status" do
      instance = create_instance()

      {:ok, pid} =
        InstanceServer.start_link(
          instance_module: TestMessaging,
          instance: instance
        )

      {:ok, status} = InstanceServer.status(pid)

      assert status.status == :starting
      assert status.instance_id == instance.id
      assert status.name == "Test Bot"
      assert status.consecutive_failures == 0
      assert status.last_error == nil
    end

    test "returns error for non-existent instance" do
      assert {:error, :not_found} = InstanceServer.status({TestMessaging, "missing"})
    end
  end

  describe "lifecycle notifications" do
    test "notify_connecting transitions to :connecting" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      InstanceServer.notify_connecting(pid)

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.status == :connecting
      end)
    end

    test "notify_connected transitions to :connected and sets timestamp" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      InstanceServer.notify_connected(pid, %{version: "1.0"})

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.status == :connected and status.connected_at != nil
      end)
    end

    test "notify_disconnected transitions to :disconnected with reason" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      InstanceServer.notify_connected(pid)

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.status == :connected
      end)

      InstanceServer.notify_disconnected(pid, :network_error)

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.status == :disconnected and status.last_error == :network_error
      end)
    end
  end

  describe "failure tracking" do
    test "notify_failure increments consecutive_failures" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      for _ <- 1..3 do
        InstanceServer.notify_failure(pid, :send_error)
      end

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.consecutive_failures == 3 and status.last_error == :send_error
      end)
    end

    test "notify_success resets consecutive_failures" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      for _ <- 1..5 do
        InstanceServer.notify_failure(pid, :error)
      end

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.consecutive_failures == 5
      end)

      InstanceServer.notify_success(pid)

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.consecutive_failures == 0
      end)
    end

    test "transitions to :error after 10 consecutive failures" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      for _ <- 1..10 do
        InstanceServer.notify_failure(pid, :repeated_error)
      end

      assert_eventually(fn ->
        {:ok, status} = InstanceServer.status(pid)
        status.status == :error and status.consecutive_failures == 10
      end)
    end
  end

  describe "get_instance/1" do
    test "returns the instance struct" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      {:ok, returned_instance} = InstanceServer.get_instance(pid)
      assert returned_instance.id == instance.id
      assert returned_instance.channel_type == :telegram
    end
  end

  describe "stop/1" do
    test "gracefully stops the server" do
      instance = create_instance()
      {:ok, pid} = InstanceServer.start_link(instance_module: TestMessaging, instance: instance)

      ref = Process.monitor(pid)
      assert :ok = InstanceServer.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end
end
