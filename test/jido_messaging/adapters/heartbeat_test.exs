defmodule Jido.Messaging.Adapters.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Adapters.Heartbeat
  alias Jido.Messaging.Instance

  defmodule HealthyChannel do
    @behaviour Jido.Messaging.Adapters.Heartbeat

    @impl true
    def check_health(_instance), do: :ok

    @impl true
    def probe_interval_ms, do: 5000
  end

  defmodule UnhealthyChannel do
    @behaviour Jido.Messaging.Adapters.Heartbeat

    @impl true
    def check_health(_instance), do: {:error, :connection_lost}

    @impl true
    def probe_interval_ms, do: 10_000
  end

  defmodule PartialChannel do
    @behaviour Jido.Messaging.Adapters.Heartbeat

    @impl true
    def check_health(_instance), do: :ok
  end

  defmodule NoHeartbeatChannel do
    def some_other_function, do: :ok
  end

  defp build_instance(attrs \\ %{}) do
    base = %{
      id: "inst_123",
      name: "Test Bot",
      channel_type: :telegram
    }

    Instance.new(Map.merge(base, attrs))
  end

  describe "check_health/2" do
    test "returns :ok for healthy channel" do
      instance = build_instance()
      assert Heartbeat.check_health(HealthyChannel, instance) == :ok
    end

    test "returns error for unhealthy channel" do
      instance = build_instance()
      assert Heartbeat.check_health(UnhealthyChannel, instance) == {:error, :connection_lost}
    end

    test "returns :ok for channel without callback" do
      instance = build_instance()
      assert Heartbeat.check_health(NoHeartbeatChannel, instance) == :ok
    end
  end

  describe "probe_interval_ms/1" do
    test "returns custom interval from channel" do
      assert Heartbeat.probe_interval_ms(HealthyChannel) == 5000
      assert Heartbeat.probe_interval_ms(UnhealthyChannel) == 10_000
    end

    test "returns default interval for channel without callback" do
      assert Heartbeat.probe_interval_ms(NoHeartbeatChannel) == 30_000
    end

    test "returns default interval for channel with partial implementation" do
      assert Heartbeat.probe_interval_ms(PartialChannel) == 30_000
    end
  end

  describe "implements?/1" do
    test "returns true for modules implementing Heartbeat behaviour" do
      assert Heartbeat.implements?(HealthyChannel)
      assert Heartbeat.implements?(UnhealthyChannel)
      assert Heartbeat.implements?(PartialChannel)
    end

    test "returns false for modules not implementing Heartbeat behaviour" do
      refute Heartbeat.implements?(NoHeartbeatChannel)
      refute Heartbeat.implements?(String)
    end
  end
end
