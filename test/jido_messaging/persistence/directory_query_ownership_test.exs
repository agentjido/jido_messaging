defmodule Jido.Messaging.Persistence.DirectoryQueryOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.Persistence
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} participant name/id/provider queries preserve exact bridge identity" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)

      first =
        Participant.new(%{id: "a", type: :human, identity: %{name: "Casey One"}, external_ids: %{slack: "shared"}})

      second =
        Participant.new(%{id: "b", type: :human, identity: %{"name" => "Casey Two"}, external_ids: %{slack: "other"}})

      unnamed = Participant.new(%{id: "c", type: :human})

      for participant <- [second, first, unnamed],
          do: assert({:ok, participant} == adapter.save_participant(state, participant))

      assert {:ok, [^first, ^second]} = adapter.directory_search(state, :participant, %{"name" => "CASEY"}, [])

      assert {:error, {:ambiguous, [^first, ^second]}} =
               adapter.directory_lookup(state, :participant, %{name: "casey"}, [])

      assert {:ok, ^second} = adapter.directory_lookup(state, :participant, %{"id" => "b"}, [])

      assert {:ok, ^first} =
               adapter.directory_lookup(state, :participant, %{channel: :slack, external_id: "shared"}, [])

      for query <- [
            %{channel: :slack},
            %{external_id: "shared"},
            %{bridge_id: "bridge"},
            %{name: "absent"},
            %{id: "missing"}
          ] do
        assert {:ok, []} = adapter.directory_search(state, :participant, query, [])
        assert {:error, :not_found} = adapter.directory_lookup(state, :participant, query, [])
      end

      assert {:error, {:invalid_directory_target, :invalid}} = adapter.directory_lookup(state, :invalid, %{}, [])
      assert {:error, :agent_directory_scope_required} = adapter.directory_search(state, :agent, %{}, [])
    end

    test "#{adapter} same external room reference stays separate in each bridge and binding deletion" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      first = Room.new(%{id: "a", type: :group, name: "Ops One"})
      second = Room.new(%{id: "b", type: :group, name: "Ops Two"})
      for room <- [second, first], do: assert({:ok, room} == adapter.save_room(state, room))
      {:ok, binding} = adapter.create_room_binding(state, first.id, :telegram, "one", "shared", %{})
      {:ok, _} = adapter.create_room_binding(state, second.id, :telegram, "two", "shared", %{})

      assert {:ok, ^first} =
               adapter.directory_lookup(
                 state,
                 :room,
                 %{channel: :telegram, bridge_id: "one", external_id: "shared"},
                 []
               )

      assert {:ok, ^second} =
               adapter.directory_lookup(
                 state,
                 :room,
                 %{"channel" => "telegram", "bridge_id" => "two", "external_id" => "shared"},
                 []
               )

      assert {:error, {:ambiguous, [^first, ^second]}} = adapter.directory_lookup(state, :room, %{name: "ops"}, [])

      for query <- [
            %{channel: :telegram, external_id: "shared"},
            %{bridge_id: "one", external_id: "shared"},
            %{channel: :telegram, bridge_id: "one"}
          ],
          do: assert({:ok, []} == adapter.directory_search(state, :room, query, []))

      assert :ok = adapter.delete_room_binding(state, binding.id)

      assert {:error, :not_found} =
               adapter.directory_lookup(
                 state,
                 :room,
                 %{channel: :telegram, bridge_id: "one", external_id: "shared"},
                 []
               )

      assert {:ok, ^second} = adapter.get_room_by_external_binding(state, :telegram, "two", "shared")
      assert {:ok, ^first} = adapter.get_room(state, first.id)
      assert {:error, :not_found} = adapter.delete_room_binding(state, binding.id)
    end

    test "#{adapter} onboarding records retain string-key ID and reject absent identity" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      flow = %{"onboarding_id" => "owned-flow", "status" => "pending", "private-state" => %{"complete" => true}}
      assert {:ok, ^flow} = adapter.save_onboarding(state, flow)
      assert {:ok, ^flow} = adapter.get_onboarding(state, "owned-flow")

      for invalid <- [%{}, %{onboarding_id: ""}, %{onboarding_id: 1}],
          do: assert({:error, :invalid_onboarding_id} == adapter.save_onboarding(state, invalid))

      assert {:error, :not_found} = adapter.get_onboarding(state, "foreign-flow")
      assert {:ok, ^flow} = adapter.get_onboarding(state, "owned-flow")
    end
  end
end
