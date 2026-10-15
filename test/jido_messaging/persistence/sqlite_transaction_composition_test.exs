defmodule Jido.Messaging.Persistence.SQLiteTransactionCompositionTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Room
  alias Jido.Messaging.Persistence.SQLite
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  setup do
    {:ok, state} = Factory.start_sqlite()
    on_exit(fn -> Factory.stop_sqlite(state) end)
    {:ok, state: state}
  end

  test "required binding callbacks use the outer connection and commit together", %{state: state} do
    room = Room.new(%{id: "plain-room", type: :group})

    assert {:ok, "bound-room"} =
             SQLite.transaction(state, fn pinned ->
               with {:ok, _} <- SQLite.save_room(pinned, room),
                    {:ok, bound} <-
                      SQLite.get_or_create_room_by_external_binding(pinned, :slack, "bridge", "external", %{
                        id: "bound-room",
                        type: :group
                      }),
                    {:ok, _} <-
                      SQLite.get_or_create_participant_by_external_binding(pinned, :slack, "bridge", "user", %{
                        id: "bound-person",
                        type: :human
                      }) do
                 {:ok, bound.id}
               end
             end)

    assert {:ok, ^room} = SQLite.get_room(state, room.id)
    assert {:ok, %{id: "bound-room"}} = SQLite.get_room_by_external_binding(state, :slack, "bridge", "external")
    assert {:ok, %{id: "bound-person"}} = SQLite.get_participant(state, "bound-person")
  end

  test "outer failure rolls back callback records and indexes", %{state: state} do
    assert {:error, :abort} =
             SQLite.transaction(state, fn pinned ->
               assert {:ok, _} =
                        SQLite.get_or_create_room_by_external_binding(pinned, :slack, "bridge", "external", %{
                          id: "bound-room",
                          type: :group
                        })

               assert {:ok, _} =
                        SQLite.get_or_create_participant_by_external_binding(pinned, :slack, "bridge", "user", %{
                          id: "bound-person",
                          type: :human
                        })

               {:error, :abort}
             end)

    assert {:error, :not_found} = SQLite.get_room(state, "bound-room")
    assert {:error, :not_found} = SQLite.get_room_by_external_binding(state, :slack, "bridge", "external")
    assert {:error, :not_found} = SQLite.get_participant(state, "bound-person")
  end

  test "a failed internal transaction prevents an outer success from committing prior writes", %{state: state} do
    room = Room.new(%{id: "prior", type: :group})

    assert {:error, _} =
             SQLite.transaction(state, fn pinned ->
               assert {:ok, ^room} = SQLite.save_room(pinned, room)

               assert {:error, _} =
                        SQLite.get_or_create_room_by_external_binding(pinned, :slack, "bridge", "external", %{
                          type: :invalid
                        })

               {:ok, :ignored_error}
             end)

    assert {:error, :not_found} = SQLite.get_room(state, room.id)
    assert {:ok, :next} = SQLite.transaction(state, fn _ -> {:ok, :next} end)
  end
end
