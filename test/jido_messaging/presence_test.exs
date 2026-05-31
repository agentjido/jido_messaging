defmodule Jido.Messaging.PresenceTest do
  use ExUnit.Case, async: false

  alias Jido.Messaging.TestMessaging

  defmodule FakePhoenixPresence do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def track(pid, topic, key, meta) do
      Agent.get_and_update(__MODULE__, fn state ->
        topic_state = Map.get(state, topic, %{})

        if Map.has_key?(topic_state, key) do
          {{:error, {:already_tracked, pid, topic, key}}, state}
        else
          state = Map.put(state, topic, Map.put(topic_state, key, meta))
          {{:ok, make_ref()}, state}
        end
      end)
    end

    def update(_pid, topic, key, meta) do
      Agent.get_and_update(__MODULE__, fn state ->
        topic_state = Map.get(state, topic, %{})

        if Map.has_key?(topic_state, key) do
          state = Map.put(state, topic, Map.put(topic_state, key, meta))
          {{:ok, make_ref()}, state}
        else
          {{:error, :not_found}, state}
        end
      end)
    end

    def untrack(_pid, topic, key) do
      Agent.update(__MODULE__, fn state ->
        update_in(state, [Access.key(topic, %{})], &Map.delete(&1, key))
      end)
    end

    def list(topic) do
      Agent.get(__MODULE__, &Map.get(&1, topic, %{}))
    end
  end

  defmodule AdapterPresence do
    use Jido.Messaging.Presence,
      messaging: Jido.Messaging.TestMessaging,
      presence: Jido.Messaging.PresenceTest.FakePhoenixPresence,
      topic: "test:presence",
      source: "test.presence",
      heartbeat_ms: 50,
      ttl_ms: 150,
      prune_ms: 10
  end

  defmodule FailingNotifier do
    def notify(_event, _presence, _signals), do: raise("notify failed")
  end

  defmodule FailingNotifierPresence do
    use Jido.Messaging.Presence,
      messaging: Jido.Messaging.TestMessaging,
      presence: Jido.Messaging.PresenceTest.FakePhoenixPresence,
      topic: "test:failing-notifier-presence",
      source: "test.presence",
      notify: {Jido.Messaging.PresenceTest.FailingNotifier, :notify, []},
      heartbeat_ms: 50,
      ttl_ms: 150,
      prune_ms: 10
  end

  setup do
    start_supervised!(TestMessaging)
    start_supervised!(FakePhoenixPresence)
    start_supervised!(AdapterPresence)

    :ok
  end

  test "touch tracks a participant and emits canonical Jido Messaging signals" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Presence"})
    {:ok, subscription_id} = TestMessaging.subscribe_signals("jido.messaging.**")

    assert {:ok, presence, signals} =
             AdapterPresence.touch("user:1", room.id, session_id: "session:1")

    assert presence.online_user_ids == ["user:1"]
    assert AdapterPresence.online?("user:1")

    assert FakePhoenixPresence.list("test:presence")["session:1"].participant_id == "user:1"

    assert Enum.map(signals, & &1.type) == [
             "jido.messaging.room.participant_joined",
             "jido.messaging.participant.presence_changed"
           ]

    assert_receive {:signal, joined}, 1_000
    assert joined.type == "jido.messaging.room.participant_joined"
    assert joined.data["participant_id"] == "user:1"
    assert joined.data["source"] == "test.presence"

    assert_receive {:signal, changed}, 1_000
    assert changed.type == "jido.messaging.participant.presence_changed"
    assert changed.data["from"] == :offline
    assert changed.data["to"] == :online

    assert {:ok, refreshed, []} =
             AdapterPresence.touch("user:1", room.id, session_id: "session:1")

    assert refreshed.online_user_ids == ["user:1"]

    :ok = TestMessaging.unsubscribe_signals(subscription_id)
  end

  test "multiple sessions keep a participant online until the last session leaves" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Presence"})

    assert {:ok, _presence, first_signals} =
             AdapterPresence.touch("user:1", room.id, session_id: "session:1")

    assert Enum.map(first_signals, & &1.type) == [
             "jido.messaging.room.participant_joined",
             "jido.messaging.participant.presence_changed"
           ]

    assert {:ok, _presence, second_signals} =
             AdapterPresence.touch("user:1", room.id, session_id: "session:2")

    assert second_signals == []

    assert {:ok, presence, left_signals} =
             AdapterPresence.mark_left("user:1", session_id: "session:1", reason: :disconnect)

    assert presence.online_user_ids == ["user:1"]
    assert left_signals == []
    refute Map.has_key?(FakePhoenixPresence.list("test:presence"), "session:1")
    assert Map.has_key?(FakePhoenixPresence.list("test:presence"), "session:2")

    assert {:ok, presence, offline_signals} =
             AdapterPresence.mark_left("user:1", session_id: "session:2", reason: :disconnect)

    assert presence.online_user_ids == []

    assert Enum.map(offline_signals, & &1.type) == [
             "jido.messaging.room.participant_left",
             "jido.messaging.participant.presence_changed"
           ]
  end

  test "room join and leave signals follow room occupancy, not session count" do
    {:ok, room_a} = TestMessaging.create_room(%{type: :group, name: "Presence A"})
    {:ok, room_b} = TestMessaging.create_room(%{type: :group, name: "Presence B"})

    assert {:ok, _presence, _signals} =
             AdapterPresence.touch("user:1", room_a.id, session_id: "session:1")

    assert {:ok, presence, second_room_signals} =
             AdapterPresence.touch("user:1", room_b.id, session_id: "session:2")

    assert presence.online_user_ids == ["user:1"]
    assert Enum.map(second_room_signals, & &1.type) == ["jido.messaging.room.participant_joined"]
    assert hd(second_room_signals).subject == room_b.id

    assert {:ok, presence, room_left_signals} =
             AdapterPresence.mark_left("user:1", session_id: "session:2", reason: :disconnect)

    assert presence.online_user_ids == ["user:1"]
    assert Enum.map(room_left_signals, & &1.type) == ["jido.messaging.room.participant_left"]
    assert hd(room_left_signals).subject == room_b.id
  end

  test "public API normalizes map options and non-string session IDs" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Presence"})

    assert {:ok, presence, _signals} =
             AdapterPresence.touch("user:1", room.id, %{session_id: 123, track_pid: self()})

    assert presence.online_user_ids == ["user:1"]
    assert Map.has_key?(FakePhoenixPresence.list("test:presence"), "123")
    assert FakePhoenixPresence.list("test:presence")["123"].track_pid == self()

    assert {:ok, presence, _signals} =
             AdapterPresence.mark_left("user:1", %{session_id: 123})

    assert presence.online_user_ids == []
  end

  test "notify callback failures do not crash the adapter" do
    start_supervised!(FailingNotifierPresence)
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Presence"})

    assert {:ok, _presence, _signals} =
             FailingNotifierPresence.touch("user:1", room.id, session_id: "notify-session")

    assert {:ok, presence, _signals} =
             FailingNotifierPresence.mark_left("user:1", session_id: "notify-session")

    assert presence.online_user_ids == []
    assert Process.alive?(Process.whereis(FailingNotifierPresence))
  end

  test "public API rejects missing or blank identifiers" do
    assert AdapterPresence.touch(nil, "room:1") == {:error, :missing_participant}
    assert AdapterPresence.touch("", "room:1") == {:error, :missing_participant}
    assert AdapterPresence.touch("user:1", nil) == {:error, :missing_room}
    assert AdapterPresence.touch("user:1", " ") == {:error, :missing_room}
    assert AdapterPresence.mark_left(nil) == {:error, :missing_participant}
  end

  test "prune expires stale sessions" do
    {:ok, room} = TestMessaging.create_room(%{type: :group, name: "Presence"})

    assert {:ok, _presence, _signals} =
             AdapterPresence.touch("user:1", room.id, session_id: "session:1", ttl_ms: 0)

    send(Process.whereis(AdapterPresence), :prune)
    Process.sleep(20)

    assert AdapterPresence.snapshot() == %{online_user_ids: []}
    refute Map.has_key?(FakePhoenixPresence.list("test:presence"), "session:1")
  end
end
