defmodule Jido.Messaging.DeadLetterTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.DeadLetter

  defmodule Instance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS, runtime_profile: :core
  end

  setup do
    previous = Application.get_env(Instance, :dead_letter)
    Application.put_env(Instance, :dead_letter, max_records: 3, replay_partitions: 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(Instance, :dead_letter, previous),
        else: Application.delete_env(Instance, :dead_letter)
    end)

    start_supervised!(Instance)
    :ok
  end

  defp capture(id, opts \\ []) do
    request = %{operation: :send, routing_key: "route:" <> id, session_key: "session:" <> id, opts: opts}

    {:ok, record} =
      DeadLetter.capture_outbound_failure(Instance, request, %{reason: :timeout, attempt: 1, max_attempts: 1}, %{
        source: "fixture"
      })

    record
  end

  test "bounded storage evicts the oldest record and preserves newest-first query order" do
    [first, second, third, fourth] = Enum.map(~w(one two three four), &capture/1)
    assert {:error, :not_found} = DeadLetter.get(Instance, first.id)
    assert {:ok, [^fourth, ^third, ^second]} = DeadLetter.list(Instance)
    assert {:ok, [^fourth]} = DeadLetter.list(Instance, limit: 1)
    assert {:ok, [^fourth, ^third, ^second]} = DeadLetter.list(Instance, limit: 0)
  end

  test "archive and default purge preserve active work and its order" do
    first = capture("one")
    second = capture("two")
    assert :ok = DeadLetter.archive(Instance, first.id)
    assert {:ok, [%{id: id, status: :archived}]} = DeadLetter.list(Instance, status: :archived)
    assert id == first.id
    assert {:ok, [^second]} = DeadLetter.list(Instance, status: :active)
    assert {:ok, 1} = DeadLetter.purge(Instance)
    assert {:ok, [^second]} = DeadLetter.list(Instance)
    assert {:error, :not_found} = DeadLetter.get(Instance, first.id)
  end

  test "age-qualified purge removes old archived work without sleeps or deleting fresh work" do
    old = capture("old")
    fresh = capture("fresh")
    :ok = DeadLetter.archive(Instance, old.id)
    pid = Process.whereis(DeadLetter.server_name(Instance))

    :sys.replace_state(pid, fn state ->
      put_in(state.records[old.id].inserted_at, DateTime.add(DateTime.utc_now(), -10, :second))
    end)

    assert {:ok, 1} = DeadLetter.purge(Instance, status: :all, older_than_ms: 5_000)
    assert {:ok, [^fresh]} = DeadLetter.list(Instance)
  end

  test "replay admission holds one attempt and returns a cached success until explicit force" do
    record = capture("one")
    assert {:ok, :replay, running} = DeadLetter.prepare_replay(Instance, record.id)
    assert running.replay.attempts == 1
    assert {:error, :replay_in_progress} = DeadLetter.prepare_replay(Instance, record.id)
    assert {:ok, completed} = DeadLetter.complete_replay(Instance, record.id, {:ok, %{id: "sent"}})
    assert completed.replay.status == :succeeded
    assert completed.replay.last_outcome == :ok
    assert {:ok, :already_replayed, ^completed} = DeadLetter.prepare_replay(Instance, record.id)
    assert {:ok, :replay, forced} = DeadLetter.prepare_replay(Instance, record.id, true)
    assert forced.replay.attempts == 2
    assert forced.replay.last_result == nil
  end

  test "a failed replay retains the outcome and permits one new attempt" do
    record = capture("failed")
    assert {:ok, :replay, _} = DeadLetter.prepare_replay(Instance, record.id)
    assert {:ok, failed} = DeadLetter.complete_replay(Instance, record.id, {:error, :timeout})
    assert failed.replay.status == :failed
    assert failed.replay.last_result == {:error, :timeout}
    assert {:ok, :replay, retried} = DeadLetter.prepare_replay(Instance, record.id)
    assert retried.replay.attempts == 2
    assert retried.replay.last_outcome == nil
  end

  test "archived and missing records cannot start a replay" do
    record = capture("archived")
    :ok = DeadLetter.archive(Instance, record.id)
    assert {:error, :archived} = DeadLetter.prepare_replay(Instance, record.id, true)
    assert {:error, :not_found} = DeadLetter.prepare_replay(Instance, "missing")
    assert {:error, :not_found} = DeadLetter.complete_replay(Instance, "missing", {:ok, %{}})
    assert {:error, :not_found} = DeadLetter.archive(Instance, "missing")
  end

  test "private correlation provenance survives keyword and map options without altering the request" do
    for {index, opts, expected} <- [
          {1, [correlation_id: "keyword"], "keyword"},
          {2, %{correlation_id: "atom-map"}, "atom-map"},
          {3, %{"correlation_id" => "string-map"}, "string-map"},
          {4, nil, "session:4"}
        ] do
      record = capture(to_string(index), opts)
      assert record.correlation_id == expected
      assert record.request.opts == opts
      assert record.diagnostics == %{source: "fixture"}
    end
  end

  test "invalid per-instance limits retain bounded defaults" do
    Application.put_env(Instance, :dead_letter, max_records: 0, replay_partitions: -1)
    assert DeadLetter.config(Instance)[:max_records] == 5_000
    assert DeadLetter.config(Instance)[:replay_partitions] > 0
  end

  test "a stopped store returns unavailable for record operations" do
    supervisor = Instance.__jido_messaging__(:supervisor)
    pid = Process.whereis(DeadLetter.server_name(Instance))
    {id, ^pid, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {_, child, _, _} -> child == pid end)
    :ok = Supervisor.terminate_child(supervisor, id)
    assert {:error, :unavailable} = DeadLetter.list(Instance)
    assert {:error, :unavailable} = DeadLetter.get(Instance, "missing")
    assert {:error, :unavailable} = DeadLetter.archive(Instance, "missing")
    assert {:error, :unavailable} = DeadLetter.purge(Instance)
  end
end
