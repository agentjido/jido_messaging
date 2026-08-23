defmodule Jido.Messaging.AgentEndpointsTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Chat.{Participant, Room}

  alias Jido.Messaging.{
    AgentEndpointDelivery,
    AgentEndpointTarget,
    AgentMessagingEndpoint,
    AgentThreadRoute,
    Message,
    RoomMembership,
    Thread
  }

  alias Jido.Messaging.Persistence.SQLite

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  defmodule MockJidokaProvider do
    @behaviour Jido.Messaging.AgentEndpointProvider

    @impl true
    def deliver(delivery, opts) do
      if delay = Keyword.get(opts, :delay), do: Process.sleep(delay)
      if notify = Keyword.get(opts, :notify), do: send(notify, {:jidoka_delivery, delivery})

      Keyword.get(
        opts,
        :result,
        {:ok,
         %{
           jidoka_session_ref: "session:1",
           jidoka_request_ref: "request:1",
           jidoka_turn_ref: "turn:1"
         }}
      )
    end
  end

  defmodule RaisingJidokaProvider do
    @behaviour Jido.Messaging.AgentEndpointProvider

    @impl true
    def deliver(_delivery, _opts), do: raise("provider failure")
  end

  setup do
    path = Path.join(System.tmp_dir!(), "jido-messaging-agent-endpoint-#{System.unique_integer([:positive])}.sqlite3")

    start_supervised!(ETSMessaging)
    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})

    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "persists Jidoka endpoints, memberships, and routes without starting agents" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      {_participant, room, thread} = create_agent_thread(messaging, prefix)

      assert {:ok, endpoint} =
               messaging.create_agent_messaging_endpoint(%{
                 principal_id: "#{prefix}-agent",
                 jidoka_agent_ref: %{system: :jidoka, id: "#{prefix}-support-agent"},
                 metadata: %{label: "Support agent"}
               })

      assert endpoint.jidoka_agent_ref == %{
               "system" => "jidoka",
               "id" => "#{prefix}-support-agent"
             }

      assert {:ok, ^endpoint} =
               messaging.get_agent_messaging_endpoint_by_ref("#{prefix}-support-agent")

      assert {:ok, membership} = messaging.add_agent_endpoint_to_room(endpoint.id, room.id)

      assert {:ok, route} =
               messaging.route_thread_to_agent_endpoint(
                 thread.id,
                 endpoint.id,
                 jidoka_session_ref: "session:initial"
               )

      assert route.endpoint_id == endpoint.id
      assert route.room_id == room.id
      assert route.jidoka_session_ref == "session:initial"
      assert messaging.count_agents() == 0
      assert {:ok, []} = messaging.list_agents(room.id)
      assert nil == Jido.Messaging.AgentRunner.whereis(messaging, room.id, thread.id, endpoint.id)

      assert {:ok, stored_thread} = messaging.get_thread(thread.id)
      assert stored_thread.assigned_agent_id == nil

      assert {:error, {:endpoint_unavailable, :unknown}} =
               messaging.resolve_agent_thread_endpoint(thread.id)

      assert {:ok, unavailable_target} = AgentEndpointTarget.new(endpoint, membership, route)

      message = create_thread_message(messaging, room.id, thread.id, "#{prefix}-message")

      assert {:error, {:endpoint_unavailable, :unknown}} =
               AgentEndpointDelivery.deliver(
                 MockJidokaProvider,
                 unavailable_target,
                 message,
                 notify: self()
               )

      refute_received {:jidoka_delivery, _delivery}

      assert {:ok, available_endpoint} =
               messaging.set_agent_endpoint_availability(
                 endpoint.id,
                 :available,
                 availability_ref: "jidoka-presence:1"
               )

      assert available_endpoint.last_seen_at
      assert {:ok, target} = messaging.resolve_agent_thread_endpoint(thread.id)

      assert {:ok, receipt} =
               AgentEndpointDelivery.deliver(MockJidokaProvider, target, message,
                 notify: self(),
                 context: %{source: :test}
               )

      assert_receive {:jidoka_delivery, first_delivery}
      assert first_delivery.context == %{source: :test}
      assert receipt.delivery_id == first_delivery.id

      assert {:ok, second_receipt} =
               AgentEndpointDelivery.deliver(MockJidokaProvider, target, message, notify: self())

      assert_receive {:jidoka_delivery, second_delivery}
      assert second_receipt.delivery_id == receipt.delivery_id
      assert second_delivery.id == first_delivery.id

      assert {:ok, correlated_route} =
               messaging.put_agent_thread_route_correlations(thread.id, receipt)

      assert correlated_route.jidoka_session_ref == "session:1"
      assert correlated_route.jidoka_request_ref == "request:1"
      assert correlated_route.jidoka_turn_ref == "turn:1"
      assert correlated_route.delivery_revision == 1

      assert {:ok, revoked_membership} =
               messaging.revoke_agent_room_membership(membership.id)

      assert revoked_membership.status == :revoked

      assert {:error, {:membership_inactive, :revoked}} =
               messaging.resolve_agent_thread_endpoint(thread.id)

      assert messaging.count_agents() == 0
    end
  end

  test "endpoint identity is unique and requires an agent participant" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      create_participant(messaging, "#{prefix}-agent-one", :agent)
      create_participant(messaging, "#{prefix}-agent-two", :agent)
      create_participant(messaging, "#{prefix}-human", :human)

      assert {:ok, endpoint} =
               messaging.create_agent_messaging_endpoint(%{
                 principal_id: "#{prefix}-agent-one",
                 jidoka_agent_ref: %{"system" => "jidoka", "id" => "#{prefix}-jidoka-one"}
               })

      endpoint_id = endpoint.id

      assert {:error, {:agent_endpoint_principal_conflict, ^endpoint_id}} =
               messaging.create_agent_messaging_endpoint(%{
                 principal_id: "#{prefix}-agent-one",
                 jidoka_agent_ref: %{"system" => "jidoka", "id" => "#{prefix}-jidoka-other"}
               })

      assert {:error, {:jidoka_agent_ref_conflict, ^endpoint_id}} =
               messaging.create_agent_messaging_endpoint(%{
                 principal_id: "#{prefix}-agent-two",
                 jidoka_agent_ref: %{"system" => "jidoka", "id" => "#{prefix}-jidoka-one"}
               })

      assert {:error, {:endpoint_principal_must_be_agent, :human}} =
               messaging.create_agent_messaging_endpoint(%{
                 principal_id: "#{prefix}-human",
                 jidoka_agent_ref: %{"system" => "jidoka", "id" => "#{prefix}-jidoka-human"}
               })
    end
  end

  test "concurrent endpoint registration, membership, and routing are idempotent" do
    for messaging <- [ETSMessaging, SQLiteMessaging] do
      prefix = prefix(messaging)
      {_participant, room, thread} = create_agent_thread(messaging, "#{prefix}-concurrent")

      endpoint_results =
        1..20
        |> Task.async_stream(
          fn _index ->
            messaging.create_agent_messaging_endpoint(%{
              principal_id: "#{prefix}-concurrent-agent",
              jidoka_agent_ref: %{system: "jidoka", id: "#{prefix}-concurrent-jidoka"}
            })
          end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {:ok, endpoint}} -> endpoint end)

      assert endpoint_results |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
      endpoint = hd(endpoint_results)

      membership_results =
        1..20
        |> Task.async_stream(
          fn _index -> messaging.add_agent_endpoint_to_room(endpoint.id, room.id) end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {:ok, membership}} -> membership end)

      assert membership_results |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

      route_results =
        1..20
        |> Task.async_stream(
          fn _index -> messaging.route_thread_to_agent_endpoint(thread.id, endpoint.id) end,
          max_concurrency: 20,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, {:ok, route}} -> route end)

      assert route_results |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
      assert {:ok, [^endpoint]} = messaging.list_agent_messaging_endpoints()
      assert {:ok, [_membership]} = messaging.list_agent_room_memberships(room.id)
      assert {:ok, [_route]} = messaging.list_agent_thread_routes(endpoint.id)
    end
  end

  test "endpoint records reject executable agent definitions and secret data" do
    assert_raise ArgumentError, ~r/permits only/, fn ->
      AgentMessagingEndpoint.new(%{
        principal_id: "unsafe-agent",
        jidoka_agent_ref: %{
          system: "jidoka",
          id: "unsafe",
          handler: fn -> :unsafe end
        }
      })
    end

    assert_raise ArgumentError, ~r/cannot contain access_token/, fn ->
      AgentMessagingEndpoint.new(%{
        principal_id: "unsafe-token-agent",
        jidoka_agent_ref: %{system: "jidoka", id: "unsafe-token"},
        metadata: %{access_token: "do-not-store"}
      })
    end

    assert_raise ArgumentError, ~r/must contain only safe data/, fn ->
      RoomMembership.new(%{
        room_id: "room",
        principal_id: "agent",
        endpoint_id: "endpoint",
        metadata: %{callback: fn -> :unsafe end}
      })
    end

    assert_raise ArgumentError, ~r/only jidoka system/, fn ->
      AgentMessagingEndpoint.new(%{
        principal_id: "other-runtime-agent",
        jidoka_agent_ref: %{system: "other-runtime", id: "agent"}
      })
    end
  end

  test "provider failures and timeouts are bounded and do not start a substitute agent" do
    participant = Participant.new(%{id: "bounded-agent", type: :agent})
    endpoint = endpoint(participant.id, "bounded-jidoka", :available)
    membership = RoomMembership.new(%{room_id: "bounded-room", principal_id: participant.id, endpoint_id: endpoint.id})

    route =
      AgentThreadRoute.new(%{
        room_id: membership.room_id,
        thread_id: "bounded-thread",
        endpoint_id: endpoint.id
      })

    {:ok, target} = AgentEndpointTarget.new(endpoint, membership, route)
    message = message("bounded-message", membership.room_id, route.thread_id)

    assert {:error, {:provider_exception, RuntimeError}} =
             AgentEndpointDelivery.deliver(RaisingJidokaProvider, target, message)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :endpoint_provider_timeout} =
             AgentEndpointDelivery.deliver(MockJidokaProvider, target, message,
               delay: 250,
               timeout: 10,
               notify: self()
             )

    assert System.monotonic_time(:millisecond) - started_at < 200
    refute_received {:jidoka_delivery, _delivery}
    assert ETSMessaging.count_agents() == 0
  end

  test "SQLite restores endpoint, membership, route, and correlations after restart" do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido-messaging-agent-endpoint-restart-#{System.unique_integer([:positive])}.sqlite3"
      )

    participant = Participant.new(%{id: "restart-agent", type: :agent})
    room = Room.new(%{id: "restart-room", type: :group})
    thread = Thread.new(%{id: "restart-thread", room_id: room.id})
    endpoint = endpoint(participant.id, "restart-jidoka", :available)

    membership =
      RoomMembership.new(%{
        room_id: room.id,
        principal_id: participant.id,
        endpoint_id: endpoint.id
      })

    route =
      AgentThreadRoute.new(%{
        room_id: room.id,
        thread_id: thread.id,
        endpoint_id: endpoint.id,
        jidoka_session_ref: "restart-session",
        jidoka_request_ref: "restart-request",
        jidoka_turn_ref: "restart-turn"
      })

    {:ok, state} = SQLite.init(path: path, instance_id: "restart-test")
    assert {:ok, ^participant} = SQLite.save_participant(state, participant)
    assert {:ok, ^room} = SQLite.save_room(state, room)
    assert {:ok, ^thread} = SQLite.save_thread(state, thread)
    assert {:ok, ^endpoint} = SQLite.save_agent_messaging_endpoint(state, endpoint)
    assert {:ok, ^membership} = SQLite.save_room_membership(state, membership)
    assert {:ok, ^route} = SQLite.save_agent_thread_route(state, route)
    :ok = Sqlite3.close(state.db)

    {:ok, restored_state} = SQLite.init(path: path, instance_id: "restart-test")
    assert {:ok, ^endpoint} = SQLite.get_agent_messaging_endpoint(restored_state, endpoint.id)
    assert {:ok, ^membership} = SQLite.get_room_membership(restored_state, room.id, endpoint.id)
    assert {:ok, ^route} = SQLite.get_agent_thread_route(restored_state, thread.id)
    :ok = Sqlite3.close(restored_state.db)
    File.rm(path)
  end

  defp create_agent_thread(messaging, prefix) do
    participant = create_participant(messaging, "#{prefix}-agent", :agent)
    {:ok, room} = messaging.create_room(%{id: "#{prefix}-room", type: :group})
    {:ok, thread} = messaging.save_thread(%{id: "#{prefix}-thread", room_id: room.id})
    {participant, room, thread}
  end

  defp create_participant(messaging, id, type) do
    {:ok, participant} = messaging.create_participant(%{id: id, type: type})
    participant
  end

  defp create_thread_message(messaging, room_id, thread_id, id) do
    {:ok, message} =
      messaging.save_message(%{
        id: id,
        room_id: room_id,
        thread_id: thread_id,
        sender_id: "human-sender",
        role: :user,
        content: [%{type: :text, text: "Invoke agent"}],
        inserted_at: DateTime.utc_now()
      })

    message
  end

  defp endpoint(principal_id, jidoka_id, availability) do
    AgentMessagingEndpoint.new(%{
      principal_id: principal_id,
      jidoka_agent_ref: %{system: "jidoka", id: jidoka_id},
      availability: availability
    })
  end

  defp message(id, room_id, thread_id) do
    Message.new(%{
      id: id,
      room_id: room_id,
      thread_id: thread_id,
      sender_id: "sender",
      role: :user,
      content: [%{type: :text, text: "Invoke"}],
      inserted_at: DateTime.utc_now()
    })
  end

  defp prefix(messaging), do: messaging |> Module.split() |> List.last() |> String.downcase()
end
