defmodule Jido.Messaging.AgentRouteRerouteTest do
  use ExUnit.Case, async: true

  defmodule ETSInstance do
    use Jido.Messaging
  end

  defmodule SQLiteInstance do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  for instance <- [ETSInstance, SQLiteInstance] do
    test "#{instance} explicit endpoint reroute retains canonical room and clears old correlations" do
      instance = unquote(instance)
      suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      path = Path.join(System.tmp_dir!(), "jido-route-reroute-#{suffix}.sqlite3")
      start_supervised!({instance, persistence_opts: [path: path]})
      on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1) end)
      {:ok, room} = instance.create_room(%{id: "owned-room", type: :group})
      {:ok, thread} = instance.save_thread(Jido.Messaging.Thread.new(%{id: "owned-thread", room_id: room.id}))

      endpoints =
        for tag <- ["first", "second"] do
          {:ok, agent} = instance.create_participant(%{id: "agent:" <> tag, type: :agent})

          {:ok, endpoint} =
            instance.create_agent_messaging_endpoint(%{
              principal_id: agent.id,
              jidoka_agent_ref: %{"system" => "jidoka", "id" => "jidoka:" <> tag}
            })

          assert {:ok, _} = instance.add_agent_endpoint_to_room(endpoint.id, room.id)
          endpoint
        end

      [first, second] = endpoints

      assert {:ok, route} =
               instance.route_thread_to_agent_endpoint(thread.id, first.id,
                 jidoka_session_ref: "old-session",
                 jidoka_request_ref: "old-request",
                 jidoka_turn_ref: "old-turn"
               )

      assert {:ok, rerouted} = instance.route_thread_to_agent_endpoint(thread.id, second.id)
      assert rerouted.id == route.id
      assert rerouted.room_id == room.id
      assert rerouted.thread_id == thread.id
      assert rerouted.endpoint_id == second.id
      assert rerouted.delivery_revision == route.delivery_revision + 1
      assert rerouted.jidoka_session_ref == nil
      assert rerouted.jidoka_request_ref == nil
      assert rerouted.jidoka_turn_ref == nil
      assert {:ok, []} = instance.list_agent_thread_routes(first.id)
      assert {:ok, [^rerouted]} = instance.list_agent_thread_routes(second.id)
      assert {:ok, ^rerouted} = instance.get_agent_thread_route(thread.id)
      assert {:ok, _} = instance.create_room(%{id: "other-room", type: :group})
      assert {:ok, _} = instance.add_agent_endpoint_to_room(second.id, "other-room")
      assert {:ok, _} = instance.save_thread(%{thread | room_id: "other-room"})

      assert {:error, :agent_thread_route_identity_immutable} =
               instance.route_thread_to_agent_endpoint(thread.id, second.id)

      assert {:ok, ^rerouted} = instance.get_agent_thread_route(thread.id)
      assert instance.count_agents() == 0
      assert {:ok, []} = instance.list_agents(room.id)
    end
  end
end
