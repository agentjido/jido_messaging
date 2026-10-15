defmodule Jido.Messaging.Persistence.ActivityScopeCleanupTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{MessagingActivityEntry, Persistence}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} activity cleanup preserves foreign principal and room records" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      for id <- ["owned-room", "other-room"] do
        room = Room.new(%{id: id, type: :group})
        assert {:ok, ^room} = adapter.save_room(state, room)
      end

      for id <- ["owned-agent", "foreign-agent"] do
        person = Participant.new(%{id: id, type: :agent})
        assert {:ok, ^person} = adapter.save_participant(state, person)
      end

      first = entry("owned-agent", "owned-room", "first", 1)
      retained = entry("owned-agent", "other-room", "retained", 2)
      foreign = entry("foreign-agent", "other-room", "foreign", 3)

      for activity <- [first, retained, foreign],
          do: assert({:ok, activity} == adapter.save_messaging_activity(state, activity))

      assert :ok = adapter.delete_room(state, "owned-room")
      assert {:error, :not_found} = adapter.get_messaging_activity(state, first.id)
      assert {:ok, ^retained} = adapter.get_messaging_activity(state, retained.id)
      assert {:ok, ^foreign} = adapter.get_messaging_activity(state, foreign.id)
      assert {:ok, [^retained]} = adapter.get_principal_activity(state, "owned-agent", ["owned-room", "other-room"])

      assert {:error, :cursor_not_found} =
               adapter.get_principal_activity(state, "owned-agent", ["other-room"], before: foreign.id)

      assert :ok = adapter.delete_participant(state, "owned-agent")
      assert {:error, :not_found} = adapter.get_messaging_activity(state, retained.id)
      assert {:ok, ^foreign} = adapter.get_messaging_activity(state, foreign.id)
      assert {:ok, []} = adapter.get_principal_activity(state, "owned-agent", ["other-room"])
      assert {:ok, [^foreign]} = adapter.get_principal_activity(state, "foreign-agent", ["other-room"])
      assert {:ok, _} = adapter.get_room(state, "other-room")
      assert {:ok, _} = adapter.get_participant(state, "foreign-agent")
    end
  end

  defp entry(principal, room, id, second) do
    MessagingActivityEntry.new(%{
      principal_id: principal,
      room_id: room,
      kind: :request,
      status: :running,
      summary: %{outcome: :none, code: "request.running"},
      execution_ref: %{
        integration_id: "fixture",
        session_id: "session:" <> id,
        request_id: "request:" <> id,
        detail_availability: :unavailable
      },
      source_event_id: "event:" <> id,
      source_event_type: "jidoka.request.started",
      source_revision: 1,
      source_recorded_at: DateTime.from_unix!(second)
    })
  end
end
