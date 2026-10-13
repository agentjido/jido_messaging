defmodule Jido.Messaging.Persistence.AgentRecordOwnershipTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{AgentMessagingEndpoint, AgentThreadRoute, Persistence, RoomMembership, Thread}
  alias Jido.Messaging.Test.PersistenceConformanceFactory, as: Factory

  for {adapter, factory, cleanup} <- [
        {Persistence.ETS, :start_ets, :stop_ets},
        {Persistence.SQLite, :start_sqlite, :stop_sqlite}
      ] do
    test "#{adapter} keeps endpoint and room membership identity across updates" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      {agent, room, thread} = records(adapter, state, "owned")
      endpoint = endpoint(agent, "owned")
      assert {:ok, ^endpoint} = adapter.save_agent_messaging_endpoint(state, endpoint)
      assert {:ok, ^endpoint} = adapter.get_agent_messaging_endpoint_by_ref(state, "jidoka:owned")

      assert {:error, :agent_endpoint_identity_immutable} =
               adapter.save_agent_messaging_endpoint(state, %{endpoint | principal_id: "foreign-principal"})

      assert {:error, {:agent_endpoint_principal_conflict, endpoint_id}} =
               adapter.save_agent_messaging_endpoint(state, %{endpoint | id: "other-endpoint"})

      assert endpoint_id == endpoint.id
      {other_agent, _, _} = records(adapter, state, "other")

      assert {:error, {:jidoka_agent_ref_conflict, ^endpoint_id}} =
               adapter.save_agent_messaging_endpoint(state, %{
                 endpoint
                 | id: "other-endpoint",
                   principal_id: other_agent.id
               })

      assert {:ok, available} = AgentMessagingEndpoint.set_availability(endpoint, :available)
      assert {:ok, ^available} = adapter.save_agent_messaging_endpoint(state, available)

      assert {:ok, [^available]} =
               adapter.list_agent_messaging_endpoints(state,
                 principal_id: agent.id,
                 availability: :available,
                 status: :active
               )

      assert {:ok, []} = adapter.list_agent_messaging_endpoints(state, availability: :unavailable)
      membership = membership(room, available, "owned")
      assert {:ok, ^membership} = adapter.save_room_membership(state, membership)

      assert {:error, :room_membership_identity_immutable} =
               adapter.save_room_membership(state, %{membership | principal_id: "foreign-principal"})

      assert {:error, {:room_membership_conflict, membership_id}} =
               adapter.save_room_membership(state, %{membership | id: "other-membership"})

      assert membership_id == membership.id

      assert {:ok, [^membership]} =
               adapter.list_room_memberships(state, room.id, endpoint_id: available.id, status: :active)

      route =
        AgentThreadRoute.new(%{id: "route:owned", room_id: room.id, thread_id: thread.id, endpoint_id: available.id})

      assert {:ok, ^route} = adapter.save_agent_thread_route(state, route)

      assert {:error, :agent_thread_route_identity_immutable} =
               adapter.save_agent_thread_route(state, %{route | room_id: "foreign-room"})

      assert {:ok, ^route} = adapter.get_agent_thread_route(state, thread.id)
      assert {:ok, [^route]} = adapter.list_agent_thread_routes(state, available.id, room_id: room.id, status: :active)
      assert {:ok, []} = adapter.list_agent_thread_routes(state, available.id, status: :revoked)
      assert {:ok, []} = adapter.list_room_memberships(state, room.id, status: :revoked)

      updated =
        AgentThreadRoute.put_correlations(route, %{jidoka_request_ref: "request:owned", jidoka_turn_ref: "turn:owned"})

      assert {:ok, ^updated} = adapter.save_agent_thread_route(state, updated)
      assert updated.delivery_revision == 1
      assert {:ok, ^updated} = adapter.get_agent_thread_route(state, thread.id)
      revoked = AgentThreadRoute.revoke(updated)
      assert {:ok, ^revoked} = adapter.save_agent_thread_route(state, revoked)
      assert {:ok, [^revoked]} = adapter.list_agent_thread_routes(state, available.id, status: :revoked)
      assert {:ok, []} = adapter.list_agent_thread_routes(state, available.id, status: :active)
    end

    test "#{adapter} deletes room agent routes while preserving another room" do
      adapter = unquote(adapter)
      {:ok, state} = apply(Factory, unquote(factory), [])
      on_exit(fn -> apply(Factory, unquote(cleanup), [state]) end)
      {agent, room, thread} = records(adapter, state, "owned")
      {foreign_agent, foreign_room, foreign_thread} = records(adapter, state, "foreign")

      for {agent, room, thread, tag} <- [
            {agent, room, thread, "owned"},
            {foreign_agent, foreign_room, foreign_thread, "foreign"}
          ] do
        endpoint = endpoint(agent, tag)
        assert {:ok, ^endpoint} = adapter.save_agent_messaging_endpoint(state, endpoint)
        assert {:ok, _} = adapter.save_room_membership(state, membership(room, endpoint, tag))

        assert {:ok, _} =
                 adapter.save_agent_thread_route(
                   state,
                   AgentThreadRoute.new(%{
                     id: "route:" <> tag,
                     room_id: room.id,
                     thread_id: thread.id,
                     endpoint_id: endpoint.id
                   })
                 )
      end

      assert :ok = adapter.delete_room(state, room.id)
      assert {:ok, []} = adapter.list_room_memberships(state, room.id)
      assert {:error, :not_found} = adapter.get_agent_thread_route(state, thread.id)
      assert {:ok, [_]} = adapter.list_room_memberships(state, foreign_room.id)
      assert {:ok, foreign_route} = adapter.get_agent_thread_route(state, foreign_thread.id)
      assert foreign_route.room_id == foreign_room.id
      assert {:ok, [_]} = adapter.list_agent_thread_routes(state, "endpoint:foreign")
      assert :ok = adapter.delete_participant(state, foreign_agent.id)
      assert {:error, :not_found} = adapter.get_agent_messaging_endpoint(state, "endpoint:foreign")
      assert {:error, :not_found} = adapter.get_agent_messaging_endpoint_by_ref(state, "jidoka:foreign")
      assert {:ok, []} = adapter.list_room_memberships(state, foreign_room.id)
      assert {:error, :not_found} = adapter.get_agent_thread_route(state, foreign_thread.id)
      assert {:ok, ^foreign_room} = adapter.get_room(state, foreign_room.id)
      assert {:ok, _} = adapter.get_agent_messaging_endpoint(state, "endpoint:owned")
    end
  end

  defp records(adapter, state, tag) do
    agent = Participant.new(%{id: "agent:" <> tag, type: :agent})
    room = Room.new(%{id: "room:" <> tag, type: :group})
    thread = Thread.new(%{id: "thread:" <> tag, room_id: room.id})
    assert {:ok, ^agent} = adapter.save_participant(state, agent)
    assert {:ok, ^room} = adapter.save_room(state, room)
    assert {:ok, ^thread} = adapter.save_thread(state, thread)
    {agent, room, thread}
  end

  defp endpoint(agent, tag),
    do:
      AgentMessagingEndpoint.new(%{
        id: "endpoint:" <> tag,
        principal_id: agent.id,
        jidoka_agent_ref: %{"system" => "jidoka", "id" => "jidoka:" <> tag}
      })

  defp membership(room, endpoint, tag),
    do:
      RoomMembership.new(%{
        id: "membership:" <> tag,
        room_id: room.id,
        endpoint_id: endpoint.id,
        principal_id: endpoint.principal_id
      })
end
