defmodule Jido.Messaging.RequestLedgerTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Errors.Contract
  alias Jido.Messaging.RequestLedger

  setup do
    %{
      table: RequestLedger.new(),
      key: {"principal", "request"},
      payload: {"operation", %{"text" => "hello"}},
      authority: {"grant", 1}
    }
  end

  test "retains successful and failed results and exact entry format", context do
    for result <- [{:ok, :completed}, {:error, :failed}] do
      key = {context.key, result}

      assert {:ok, {^key, digest, authority} = claim} =
               RequestLedger.claim(context.table, key, context.payload, context.authority)

      assert [{^key, ^digest, ^authority, {:running, owner}}] = :ets.lookup(context.table, key)
      assert owner == self()
      assert :ok = RequestLedger.complete(context.table, claim, result)
      assert [{^key, ^digest, ^authority, {:done, ^result}}] = :ets.lookup(context.table, key)
      assert {:cached, ^result} = RequestLedger.claim(context.table, key, context.payload, context.authority)
    end
  end

  test "key includes principal; digest is independent of map insertion order", context do
    payload = {"operation", Map.new([{"a", 1}, {"b", 2}])}
    reversed = {"operation", Map.new([{"b", 2}, {"a", 1}])}
    assert {:ok, claim} = RequestLedger.claim(context.table, context.key, payload, context.authority)
    :ok = RequestLedger.complete(context.table, claim, :result)
    assert {:cached, :result} = RequestLedger.claim(context.table, context.key, reversed, context.authority)
    assert {:ok, _} = RequestLedger.claim(context.table, {"other-principal", "request"}, payload, context.authority)
  end

  test "changed payload or authority does not release a completed ID", context do
    assert {:ok, claim} = RequestLedger.claim(context.table, context.key, context.payload, context.authority)
    :ok = RequestLedger.complete(context.table, claim, :result)

    assert {:error, %Contract{code: :request_conflict}} =
             RequestLedger.claim(context.table, context.key, :changed, context.authority)

    assert {:error, %Contract{code: :request_conflict}} =
             RequestLedger.claim(context.table, context.key, context.payload, {"grant", 2})

    assert {:cached, :result} = RequestLedger.claim(context.table, context.key, context.payload, context.authority)
  end

  test "a live request stays in progress; a dead owner stays unknown", context do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {:claim, RequestLedger.claim(context.table, context.key, context.payload, context.authority)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claim, {:ok, _}}

    assert {:error, %Contract{code: :request_in_progress}} =
             RequestLedger.claim(context.table, context.key, context.payload, context.authority)

    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    for _ <- 1..3 do
      assert {:error, %Contract{code: :request_outcome_unknown}} =
               RequestLedger.claim(context.table, context.key, context.payload, context.authority)
    end

    assert :ets.info(context.table, :size) == 1
  end

  test "completed IDs have no size eviction and resource entries stay unchanged", context do
    resource = {{:resource, "resource-id"}, %{kind: "result", value: :private}}
    :ets.insert(context.table, resource)

    for index <- 1..1_001 do
      key = {"principal", "request-#{index}"}
      {:ok, claim} = RequestLedger.claim(context.table, key, context.payload, context.authority)
      :ok = RequestLedger.complete(context.table, claim, index)
    end

    assert {:cached, 1} =
             RequestLedger.claim(context.table, {"principal", "request-1"}, context.payload, context.authority)

    assert [^resource] = :ets.lookup(context.table, {:resource, "resource-id"})
    assert :ets.info(context.table, :size) == 1_002
  end
end
