defmodule Jido.Messaging.ActivityInputBoundaryTest do
  use ExUnit.Case, async: false
  alias Jido.Messaging.{Persistence.ETS, Runtime}

  defmodule Store do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), name != :save_messaging_activity do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def save_messaging_activity(state, entry) do
      Agent.update(__MODULE__.Control, &(&1 + 1))
      ETS.save_messaging_activity(state, entry)
    end
  end

  defmodule Instance do
    use Jido.Messaging, persistence: Store, runtime_profile: :core
  end

  setup do
    start_supervised!(%{id: Store.Control, start: {Agent, :start_link, [fn -> 0 end, [name: Store.Control]]}})
    start_supervised!(Instance)
    contexts = Enum.map(["owned", "foreign"], &seed/1)

    records =
      for c <- contexts do
        assert {:ok, record} = Instance.project_messaging_activity(attrs(c))
        record
      end

    Agent.update(Store.Control, fn _ -> 0 end)
    runtime = Instance.__jido_messaging__(:runtime)
    {_store, state} = Runtime.get_persistence(runtime)
    {:ok, contexts: contexts, owned: hd(contexts), records: records, runtime: runtime, state: state}
  end

  test "malformed required and optional canonical references cannot write", context do
    for field <- [:principal_id, :room_id, :thread_id, :message_id, :source_event_id],
        value <- [1, " ", String.duplicate("x", 513), <<255>>, "bad\0id"] do
      reject(Map.put(attrs(context.owned), field, value), context)
    end
  end

  test "malformed execution references cannot replace canonical correlation", context do
    for field <- [:integration_id, :session_id, :request_id, :turn_id, :handoff_id, :approval_id, :detail_ref],
        value <- [1, " ", String.duplicate("x", 513), <<255>>, "bad\0id"] do
      reject(put_in(attrs(context.owned), [:execution_ref, field], value), context)
    end
  end

  test "invalid summary values and status combinations retain full history", context do
    input = attrs(context.owned)

    for {field, values} <- [
          label: [1, <<255>>, "bad\0label", String.duplicate("x", 513)],
          code: [1, "bad code", String.duplicate("x", 129)],
          outcome: [:invalid, "invalid", 1]
        ] do
      for value <- values, do: reject(put_in(input, [:summary, field], value), context)
    end

    reject(put_in(input, [:summary, :outcome], :failed), context)
    for field <- [:kind, :status], value <- [:invalid, "invalid", 1], do: reject(Map.put(input, field, value), context)
  end

  test "invalid revisions, times and event codes have zero save callbacks", context do
    input = attrs(context.owned)

    for {field, values} <- [
          source_revision: [nil, 0, -1, "1"],
          source_recorded_at: [nil, 1, "now"],
          source_event_type: [nil, 1, " ", "bad code", String.duplicate("x", 129)]
        ] do
      for value <- values, do: reject(Map.put(input, field, value), context)
    end

    for value <- [1, "now"], do: reject(put_in(input, [:execution_ref, :detail_expires_at], value), context)

    for value <- [:invalid, "invalid", 1],
        do: reject(put_in(input, [:execution_ref, :detail_availability], value), context)

    reject(put_in(input, [:execution_ref, :detail_ref], nil), context)
    reject(put_in(input, [:execution_ref, :detail_availability], :unavailable), context)
  end

  test "unsafe and duplicate fields reject at every nested boundary", context do
    input = attrs(context.owned)

    for field <- [:token, :output, :memory] do
      reject(Map.put(input, field, self()), context)
      reject(put_in(input, [:execution_ref, field], self()), context)
      reject(put_in(input, [:summary, field], self()), context)
    end

    reject(Map.put(input, "principal_id", "foreign-agent"), context)
    reject(put_in(input, [:execution_ref, "session_id"], "foreign-session"), context)
    reject(put_in(input, [:summary, "outcome"], "failed"), context)
  end

  test "string-key replay preserves the complete stored projection", context do
    input = attrs(context.owned) |> string_keys()
    original = hd(context.records)
    assert {:ok, ^original} = Instance.project_messaging_activity(input)
    assert Agent.get(Store.Control, & &1) == 1
    assert_records(context)
    assert_no_authority(context)
  end

  test "valid string enums and maximum summary fields remain complete", context do
    label = String.duplicate("é", 256)
    code = String.duplicate("x", 128)

    entries =
      for kind <- ~w(request turn approval handoff outcome),
          status <- ~w(pending running waiting approved denied completed failed cancelled unavailable) do
        input =
          attrs(context.owned)
          |> Map.merge(%{
            kind: kind,
            status: status,
            source_event_id: "new-#{kind}-#{status}",
            summary: %{outcome: "unknown", label: label, code: code}
          })

        assert {:ok, entry} = Instance.project_messaging_activity(input)
        assert Atom.to_string(entry.kind) == kind
        assert Atom.to_string(entry.status) == status
        assert entry.summary.label == label and entry.summary.code == code
        assert entry.summary.outcome == :unknown
        assert {:ok, ^entry} = ETS.get_messaging_activity(context.state, entry.id)
        entry
      end

    assert length(entries) == 45
    assert Agent.get(Store.Control, & &1) == 45
    assert_records(context)
    assert_no_authority(context)
  end

  defp seed(prefix) do
    {:ok, room} = Instance.create_room(%{id: prefix <> "-room", type: :group})
    {:ok, agent} = Instance.create_participant(%{id: prefix <> "-agent", type: :agent})
    {:ok, thread} = Instance.save_thread(%{id: prefix <> "-thread", room_id: room.id, status: :active})

    {:ok, message} =
      Instance.save_message(%{
        id: prefix <> "-message",
        room_id: room.id,
        thread_id: thread.id,
        sender_id: agent.id,
        role: :assistant,
        content: [%{type: :text, text: "Complete " <> prefix}],
        metadata: %{complete: prefix}
      })

    %{prefix: prefix, room: room, agent: agent, thread: thread, message: message, time: DateTime.utc_now()}
  end

  defp attrs(c) do
    %{
      principal_id: c.agent.id,
      room_id: c.room.id,
      thread_id: c.thread.id,
      message_id: c.message.id,
      kind: :outcome,
      status: :completed,
      summary: %{outcome: :succeeded, code: "activity.complete", label: "Complete " <> c.prefix},
      execution_ref: %{
        integration_id: "fixture",
        session_id: c.prefix <> "-session",
        request_id: c.prefix <> "-request",
        turn_id: "turn",
        handoff_id: "handoff",
        approval_id: "approval",
        detail_ref: "jidoka://detail/" <> c.prefix,
        detail_availability: :available,
        detail_expires_at: DateTime.add(c.time, 3_600, :second)
      },
      source_event_id: c.prefix <> "-event",
      source_event_type: "jidoka.activity.complete",
      source_revision: 1,
      source_recorded_at: c.time
    }
  end

  defp reject(input, context) do
    assert {:error, :invalid_messaging_activity_projection} = Instance.project_messaging_activity(input)
    assert Agent.get(Store.Control, & &1) == 0
    assert_records(context)
    assert_no_authority(context)
  end

  defp assert_records(context) do
    for record <- context.records, do: assert({:ok, record} == ETS.get_messaging_activity(context.state, record.id))

    for c <- context.contexts do
      assert {:ok, room} = ETS.get_room(context.state, c.room.id)
      assert room == c.room
      assert {:ok, agent} = ETS.get_participant(context.state, c.agent.id)
      assert agent == c.agent
      assert {:ok, thread} = ETS.get_thread(context.state, c.thread.id)
      assert thread == c.thread
      assert {:ok, message} = ETS.get_message(context.state, c.message.id)
      assert message == c.message
    end
  end

  defp assert_no_authority(context) do
    assert :ets.info(Runtime.request_table(context.runtime), :size) == 0
    assert :ets.info(context.state.memberships, :size) == 0
    assert :ets.info(context.state.principal_grants, :size) == 0
    assert Instance.count_agents() == 0
  end

  defp string_keys(value) when is_map(value) and not is_struct(value),
    do:
      Map.new(value, fn {key, nested} -> {if(is_atom(key), do: Atom.to_string(key), else: key), string_keys(nested)} end)

  defp string_keys(value) when is_list(value), do: Enum.map(value, &string_keys/1)
  defp string_keys(value), do: value
end
