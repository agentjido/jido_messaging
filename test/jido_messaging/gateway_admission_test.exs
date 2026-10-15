defmodule Jido.Messaging.GatewayAdmissionTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.OutboundGateway.Admission
  alias Jido.Messaging.DeadLetter.RejectionBuffer

  setup do
    Admission.new(__MODULE__)

    config = %{
      queue_capacity: 64,
      max_attempts: 3,
      partition: 0,
      pressure_policy: [warn_ratio: 0.5, degraded_ratio: 0.75, shed_ratio: 1.0]
    }

    epoch = Admission.open(__MODULE__, 0, config)
    %{epoch: epoch, config: config, coordinator: self()}
  end

  test "10,000 simultaneous reservations never exceed capacity", %{coordinator: coordinator} do
    parent = self()

    callers =
      for _ <- 1..10_000 do
        spawn(fn ->
          receive do
            :start -> send(parent, {:reserved, self(), Admission.reserve(__MODULE__, 0, coordinator)})
          end
        end)
      end

    Enum.each(callers, &send(&1, :start))

    results =
      for _ <- callers do
        assert_receive {:reserved, owner, result}, 10_000
        {owner, result}
      end

    held = for {owner, {:ok, permit}} <- results, do: {owner, permit}
    assert length(held) == 64
    assert Enum.count(results, &match?({_, {:error, :queue_full}}, &1)) == 9_936
    assert {:ok, _, %{load: 64}} = Admission.snapshot(__MODULE__, 0, coordinator)

    for {owner, permit} <- held do
      assert :ok = Admission.accept(permit, owner)
      Admission.abandon(permit)
    end

    assert {:ok, _, %{load: 64}} = Admission.snapshot(__MODULE__, 0, coordinator)

    for {_, permit} <- held do
      Admission.release(permit)
      Admission.release(permit)
    end

    assert {:ok, _, %{load: 0}} = Admission.snapshot(__MODULE__, 0, coordinator)
  end

  test "reaping frees only abandoned reservations, never accepted work", %{epoch: epoch, coordinator: coordinator} do
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    {:ok, reserved} = Admission.reserve(__MODULE__, 0, coordinator, dead)
    {:ok, accepted} = Admission.reserve(__MODULE__, 0, coordinator, dead)
    assert :ok = Admission.accept(accepted, dead)
    assert :ok = Admission.reap(__MODULE__, 0, epoch)
    assert {:error, :partition_unavailable} = Admission.accept(reserved, dead)
    assert {:ok, _, %{load: 1}} = Admission.snapshot(__MODULE__, 0, coordinator)
    Admission.release(accepted)
    assert {:ok, _, %{load: 0}} = Admission.snapshot(__MODULE__, 0, coordinator)
  end

  test "old generations and duplicate completion cannot release a new job", context do
    {:ok, old} = Admission.reserve(__MODULE__, 0, self())
    :ok = Admission.accept(old, self())
    epoch = Admission.open(__MODULE__, 0, context.config)
    {:ok, new} = Admission.reserve(__MODULE__, 0, self())
    :ok = Admission.accept(new, self())
    Admission.close(__MODULE__, 0, context.epoch)
    Admission.release(old)
    assert {:ok, ^epoch, %{load: 1}} = Admission.snapshot(__MODULE__, 0, self())
    Admission.release(new)
    assert {:ok, ^epoch, %{load: 0}} = Admission.snapshot(__MODULE__, 0, self())
    Admission.close(__MODULE__, 0, epoch)
    assert {:error, :partition_unavailable} = Admission.reserve(__MODULE__, 0, self())
  end

  test "wrong owner and abandoned submissions cannot be accepted" do
    {:ok, permit} = Admission.reserve(__MODULE__, 0, self())
    assert {:error, :partition_unavailable} = Admission.accept(permit, spawn(fn -> :ok end))
    Admission.abandon(permit)
    assert {:error, :partition_unavailable} = Admission.accept(permit, self())
    assert {:ok, _, %{load: 0}} = Admission.snapshot(__MODULE__, 0, self())
  end

  test "an unavailable or starting rejection buffer does not fail dispatch" do
    assert {:error, :unavailable} = RejectionBuffer.put(__MODULE__, %{id: 1})
    RejectionBuffer.new(__MODULE__, 32)
    :ets.delete(RejectionBuffer.table(__MODULE__), :limit)
    assert {:error, :unavailable} = RejectionBuffer.put(__MODULE__, %{id: 2})
  end

  test "rejection records stay bounded under a concurrent burst" do
    RejectionBuffer.new(__MODULE__, 32)

    1..1_000
    |> Task.async_stream(fn id -> RejectionBuffer.put(__MODULE__, %{id: id, payload: "$1"}) end,
      max_concurrency: 64,
      timeout: 10_000
    )
    |> Enum.each(fn result -> assert match?({:ok, {:ok, _}}, result) end)

    assert :ets.info(RejectionBuffer.table(__MODULE__), :size) == 34
    records = RejectionBuffer.take(__MODULE__)
    assert length(records) == 32
    assert length(Enum.uniq_by(records, & &1.id)) == 32
    assert RejectionBuffer.take(__MODULE__) == []
    assert :ets.info(RejectionBuffer.table(__MODULE__), :size) == 2
  end
end
