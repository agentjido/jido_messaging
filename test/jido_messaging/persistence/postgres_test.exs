defmodule Jido.Messaging.Persistence.PostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  import Jido.Messaging.TestHelpers

  alias Jido.Chat.{Participant, Room}
  alias Jido.Messaging.{BridgeConfig, IngressSubscription, Message, Persistence.Postgres, Runtime}

  defmodule RuntimeMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.Postgres
  end

  test "runs migrations concurrently and reports the current schema" do
    results =
      1..4
      |> Task.async_stream(
        fn _index -> Postgres.migrate(url: database_url(), pool_size: 1) end,
        max_concurrency: 4,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == [:ok, :ok, :ok, :ok]

    state = start_state()

    assert {:ok, %{database_version: 1, current_version: 1, pending_versions: []}} =
             Postgres.migration_status(state)
  end

  test "rejects migration versions that the package does not own" do
    state = start_state()

    assert {:ok, _result} =
             Postgrex.query(
               state.conn,
               "INSERT INTO jido_messaging_schema_migrations (version, name) VALUES ($1, $2)",
               [0, "unknown"]
             )

    on_exit(fn ->
      Postgrex.query(
        state.conn,
        "DELETE FROM jido_messaging_schema_migrations WHERE version = $1",
        [0]
      )
    end)

    assert {:error, {:unsupported_schema_version, 0, 1}} = Postgres.migration_status(state)
    assert {:error, {:unsupported_schema_version, 0, 1}} = Postgres.migrate(state)
  end

  test "requires migrations and installs them in a host schema" do
    admin = start_state()
    schema = "jido_messaging_test_#{System.unique_integer([:positive, :monotonic])}"
    assert {:ok, _result} = Postgrex.query(admin.conn, "CREATE SCHEMA #{schema}", [])

    {:ok, pool} =
      database_options()
      |> Keyword.put(:parameters, search_path: schema)
      |> Keyword.put(:pool_size, 2)
      |> Postgrex.start_link()

    Process.unlink(pool)

    on_exit(fn ->
      if Process.alive?(pool), do: GenServer.stop(pool)
      Postgrex.query(admin.conn, "DROP SCHEMA IF EXISTS #{schema} CASCADE", [])
    end)

    state = %Postgres{
      conn: pool,
      pool: pool,
      instance_id: "schema-test",
      owned_pool?: false
    }

    assert {:error, {:migration_required, 0, [1]}} = Postgres.health_check(state)

    assert {:error, {:migration_required, 0, [1]}} =
             Postgres.init(pool: pool, instance_id: "schema-test")

    assert :ok = Postgres.migrate(pool: pool)
    assert {:ok, initialized} = Postgres.init(pool: pool, instance_id: "schema-test")
    assert :ok = Postgres.health_check(initialized)
  end

  test "supports connection option boundaries and validates configuration" do
    assert {:ok, direct} =
             Postgres.init(
               database_options() ++
                 [instance_id: " ", pool_size: 1]
             )

    Process.unlink(direct.pool)
    on_exit(fn -> Postgres.close(direct) end)
    assert direct.instance_id == "default"

    assert {:ok, wrapped} =
             Postgres.init(
               connection_options: Keyword.put(database_options(), :pool_size, 1),
               instance_id: unique_id("connection-options")
             )

    Process.unlink(wrapped.pool)
    on_exit(fn -> cleanup_state(wrapped) end)

    assert {:ok, ssl_disabled} =
             Postgres.init(
               url: database_url_with_query("sslmode=disable"),
               pool_size: 1,
               instance_id: unique_id("ssl-disabled")
             )

    Process.unlink(ssl_disabled.pool)
    on_exit(fn -> cleanup_state(ssl_disabled) end)

    assert {:error, :invalid_connection_options} =
             Postgres.init(connection_options: :not_a_keyword_list)

    assert {:error, :invalid_database_url} = Postgres.init(url: :not_a_url)
    assert {:error, :invalid_database_url} = Postgres.init(url: "mysql://localhost/database")

    assert {:error, :invalid_database_ssl_mode} =
             Postgres.init(url: database_url_with_query("sslmode=unknown"))

    assert {:error, :invalid_migrate_option} =
             Postgres.init(url: database_url(), pool_size: 1, migrate: :sometimes)
  end

  test "reports production storage capabilities and health" do
    state = start_state()

    assert Postgres.capabilities(state) == [:durable, :transactions, :concurrent_writers]
    refute :transactional_delivery in Postgres.capabilities(state)
    assert :ok = Postgres.health_check(state)
  end

  test "keeps host-owned pool ownership with the host" do
    owner = start_state()
    external_instance_id = unique_id("external-pool")

    assert {:ok, external} =
             Postgres.init(pool: owner.pool, instance_id: external_instance_id)

    assert external.owned_pool? == false
    assert :ok = Postgres.close(external)
    assert Process.alive?(owner.pool)

    on_exit(fn -> delete_instance(owner, external_instance_id) end)
  end

  test "runtime supplies its namespace and closes its owned pool" do
    start_supervised!(
      {RuntimeMessaging,
       persistence_opts: [
         url: database_url(),
         migrate: true,
         pool_size: 2
       ]}
    )

    {Postgres, state} = Runtime.get_persistence(RuntimeMessaging.__jido_messaging__(:runtime))
    assert state.instance_id == Atom.to_string(RuntimeMessaging)
    assert Process.alive?(state.pool)
    assert RuntimeMessaging.persistence_capabilities() == [:durable, :transactions, :concurrent_writers]
    assert :ok = RuntimeMessaging.persistence_health()

    delete_instance(state, state.instance_id)
    pool = state.pool
    assert :ok = stop_supervised(RuntimeMessaging)

    assert :ok = assert_eventually(fn -> not Process.alive?(pool) end, timeout: 500)
  end

  test "rolls all writes back when a transaction fails" do
    state = start_state()
    room = Room.new(%{id: unique_id("rollback-room"), type: :direct})
    participant = Participant.new(%{id: unique_id("rollback-participant"), type: :human})

    assert {:error, :forced_rollback} =
             Postgres.transaction(state, fn transaction_state ->
               assert {:ok, ^room} = Postgres.save_room(transaction_state, room)
               assert {:ok, ^participant} = Postgres.save_participant(transaction_state, participant)
               {:error, :forced_rollback}
             end)

    assert {:error, :not_found} = Postgres.get_room(state, room.id)
    assert {:error, :not_found} = Postgres.get_participant(state, participant.id)

    assert {:error, {:invalid_transaction_result, :invalid}} =
             Postgres.transaction(state, fn _transaction_state -> :invalid end)

    assert {:error, %RuntimeError{message: "transaction failure"}} =
             Postgres.transaction(state, fn _transaction_state -> raise "transaction failure" end)
  end

  test "commits related writes in one transaction" do
    state = start_state()
    room = Room.new(%{id: unique_id("commit-room"), type: :direct})
    participant = Participant.new(%{id: unique_id("commit-participant"), type: :human})

    assert {:ok, {^room, ^participant}} =
             Postgres.transaction(state, fn transaction_state ->
               with {:ok, room} <- Postgres.save_room(transaction_state, room),
                    {:ok, participant} <-
                      Postgres.save_participant(transaction_state, participant) do
                 {:ok, {room, participant}}
               end
             end)

    assert {:ok, ^room} = Postgres.get_room(state, room.id)
    assert {:ok, ^participant} = Postgres.get_participant(state, participant.id)
  end

  test "keeps two instances isolated in one database" do
    first = start_state(unique_id("instance-one"))
    second = start_state(unique_id("instance-two"))
    shared_id = unique_id("shared-room")
    first_room = Room.new(%{id: shared_id, type: :direct, name: "First"})
    second_room = Room.new(%{id: shared_id, type: :group, name: "Second"})

    assert {:ok, ^first_room} = Postgres.save_room(first, first_room)
    assert {:error, :not_found} = Postgres.get_room(second, shared_id)
    assert {:ok, ^second_room} = Postgres.save_room(second, second_room)
    assert {:ok, ^first_room} = Postgres.get_room(first, shared_id)
    assert {:ok, ^second_room} = Postgres.get_room(second, shared_id)
  end

  test "recovers persisted records with a new pool" do
    instance_id = unique_id("restart")
    first = start_state(instance_id)
    message = message(unique_id("restart-message"))

    assert {:ok, ^message} = Postgres.save_message(first, message)
    assert :ok = Postgres.close(first)

    restarted = start_state(instance_id)
    assert {:ok, ^message} = Postgres.get_message(restarted, message.id)
  end

  test "resolves room and participant binding races across pools" do
    instance_id = unique_id("binding-race")
    first = start_state(instance_id)
    second = start_state(instance_id)
    states = [first, second]
    room_external_id = unique_id("external-room")
    participant_external_id = unique_id("external-participant")

    room_ids =
      1..16
      |> Task.async_stream(
        fn index ->
          state = Enum.at(states, rem(index, 2))

          Postgres.get_or_create_room_by_external_binding(
            state,
            :slack,
            "workspace-1",
            room_external_id,
            %{type: :channel, name: "Concurrent room"}
          )
        end,
        max_concurrency: 16,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, {:ok, room}} -> room.id end)

    participant_ids =
      1..16
      |> Task.async_stream(
        fn index ->
          state = Enum.at(states, rem(index, 2))

          Postgres.get_or_create_participant_by_external_binding(
            state,
            :slack,
            "workspace-1",
            participant_external_id,
            %{type: :human, identity: %{name: "Concurrent participant"}}
          )
        end,
        max_concurrency: 16,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, {:ok, participant}} -> participant.id end)

    assert length(Enum.uniq(room_ids)) == 1
    assert length(Enum.uniq(participant_ids)) == 1
    assert {:ok, [room]} = Postgres.list_rooms(first, limit: 100)
    assert room.id == hd(room_ids)
    assert {:ok, [participant]} = Postgres.directory_search(first, :participant, %{}, [])
    assert participant.id == hd(participant_ids)
  end

  test "applies one receipt during concurrent updates from separate pools" do
    instance_id = unique_id("receipt-race")
    first = start_state(instance_id)
    second = start_state(instance_id)
    states = [first, second]
    message = message(unique_id("receipt-message"))

    assert {:ok, ^message} = Postgres.save_message(first, message)

    results =
      1..12
      |> Task.async_stream(
        fn offset ->
          state = Enum.at(states, rem(offset, 2))

          Postgres.mark_message_read(state, message.id, "reader-1", %{
            bridge_id: "workspace-1",
            external_message_id: "provider-message",
            read_at: DateTime.add(~U[2026-08-20 12:00:00Z], offset)
          })
        end,
        max_concurrency: 12,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _message, :updated}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _message, :unchanged}, &1)) == 11
  end

  test "pages participant history and rejects invalid cursors" do
    state = start_state()
    room_id = unique_id("history-room")
    participant_id = unique_id("history-participant")
    base = ~U[2026-08-20 12:00:00Z]

    messages =
      for offset <- 1..4 do
        message =
          Message.new(%{
            id: unique_id("history-message"),
            room_id: room_id,
            sender_id: participant_id,
            role: :user,
            content: [%{type: :text, text: Integer.to_string(offset)}],
            status: :sent,
            inserted_at: DateTime.add(base, offset)
          })

        assert {:ok, ^message} = Postgres.save_message(state, message)
        message
      end

    assert {:ok, []} = Postgres.get_participant_messages(state, participant_id, [], limit: 10)
    assert {:error, :invalid_limit} = Postgres.get_participant_messages(state, participant_id, [room_id], limit: 0)

    assert {:ok, before} =
             Postgres.get_participant_messages(
               state,
               participant_id,
               [room_id],
               before: List.last(messages).id,
               limit: 10
             )

    assert Enum.map(before, & &1.id) == messages |> Enum.take(3) |> Enum.map(& &1.id)

    assert {:ok, after_page} =
             Postgres.get_participant_messages(
               state,
               participant_id,
               [room_id],
               after: Enum.at(messages, 1).id,
               limit: 10
             )

    assert Enum.map(after_page, & &1.id) == messages |> Enum.drop(2) |> Enum.map(& &1.id)

    assert {:error, :cursor_not_found} =
             Postgres.get_participant_messages(
               state,
               participant_id,
               [room_id],
               before: "missing",
               limit: 10
             )

    assert {:error, :invalid_cursor_options} =
             Postgres.get_participant_messages(
               state,
               participant_id,
               [room_id],
               before: hd(messages).id,
               after: List.last(messages).id
             )

    assert {:error, :cursor_not_found} =
             Postgres.get_messages(state, room_id, before: "missing", limit: 10)

    assert {:error, :invalid_cursor_options} =
             Postgres.get_messages(state, room_id,
               before: hd(messages).id,
               after: List.last(messages).id
             )
  end

  test "supports directory lookup, room filters, and ambiguity" do
    state = start_state()
    first = Room.new(%{id: "42", type: :group, name: "Shared Room"})
    second = Room.new(%{id: unique_id("directory-room"), type: :group, name: "Shared Room"})
    third = Room.new(%{id: unique_id("directory-room"), type: :group})

    for room <- [first, second, third] do
      assert {:ok, ^room} = Postgres.save_room(state, room)
    end

    external_id = unique_id("directory-external-room")

    assert {:ok, _binding} =
             Postgres.create_room_binding(
               state,
               first.id,
               :slack,
               "workspace-1",
               external_id,
               %{}
             )

    assert {:ok, ^first} = Postgres.lookup(state, :room, %{id: 42})
    assert {:ok, [^first, ^second]} = Postgres.search(state, :room, %{name: "shared"})
    assert {:error, {:ambiguous, [^first, ^second]}} = Postgres.directory_lookup(state, :room, %{name: "room"})
    assert {:error, :not_found} = Postgres.directory_lookup(state, :room, %{name: "missing"})

    assert {:ok, [^first]} =
             Postgres.directory_search(
               state,
               :room,
               %{channel: :slack, bridge_id: "workspace-1", external_id: external_id},
               []
             )

    assert {:ok, []} = Postgres.directory_search(state, :room, %{channel: :slack}, [])
    assert {:ok, []} = Postgres.directory_search(state, :room, %{name: "shared", id: third.id}, [])
    assert {:error, {:invalid_directory_target, :thread}} = Postgres.search(state, :thread, %{})
  end

  test "keeps participant binding claims atomic and repairs stale bindings" do
    state = start_state()
    external_id = unique_id("manual-binding")
    first = Participant.new(%{id: unique_id("participant"), type: :human})
    second = Participant.new(%{id: unique_id("participant"), type: :human})

    assert {:ok, ^first} = Postgres.save_participant(state, first)
    assert {:ok, ^second} = Postgres.save_participant(state, second)
    assert :ok = Postgres.bind_participant_external_id(state, first.id, :slack, "workspace-1", external_id)
    assert :ok = Postgres.bind_participant_external_id(state, first.id, :slack, "workspace-1", external_id)

    assert {:error, {:external_identity_conflict, first_id}} =
             Postgres.bind_participant_external_id(state, second.id, :slack, "workspace-1", external_id)

    assert first_id == first.id

    assert {:ok, _result} =
             Postgrex.query(
               state.conn,
               "DELETE FROM jido_messaging_records WHERE instance_id = $1 AND kind = 'participant' AND id = $2",
               [state.instance_id, first.id]
             )

    assert :ok = Postgres.bind_participant_external_id(state, second.id, :slack, "workspace-1", external_id)

    legacy_external_id = unique_id("legacy-participant")

    legacy =
      Participant.new(%{
        id: unique_id("legacy"),
        type: :human,
        external_ids: %{discord: legacy_external_id}
      })

    assert {:ok, ^legacy} = Postgres.save_participant(state, legacy)

    assert {:ok, ^legacy} =
             Postgres.get_or_create_participant_by_external_binding(
               state,
               :discord,
               "workspace-2",
               legacy_external_id,
               %{type: :human}
             )

    assert {:ok, default_bound} =
             Postgres.get_or_create_participant_by_external_id(
               state,
               :telegram,
               unique_id("default-binding"),
               %{type: :human}
             )

    assert default_bound.type == :human
  end

  test "filters bridge control-plane records" do
    state = start_state()

    enabled =
      BridgeConfig.new(%{
        id: unique_id("enabled-bridge"),
        adapter_module: Jido.Messaging.Adapters.Heartbeat,
        enabled: true
      })

    disabled =
      BridgeConfig.new(%{
        id: unique_id("disabled-bridge"),
        adapter_module: Jido.Messaging.Adapters.Heartbeat,
        enabled: false
      })

    assert {:ok, ^enabled} = Postgres.save_bridge_config(state, enabled)
    assert {:ok, ^disabled} = Postgres.save_bridge_config(state, disabled)
    assert {:ok, [^disabled, ^enabled]} = Postgres.list_bridge_configs(state)
    assert {:ok, [^enabled]} = Postgres.list_bridge_configs(state, enabled: true)

    subscription =
      IngressSubscription.new(%{
        bridge_id: enabled.id,
        adapter_name: :heartbeat,
        subscription_id: unique_id("subscription"),
        status: :active
      })

    assert {:ok, ^subscription} = Postgres.save_ingress_subscription(state, subscription)
    assert {:ok, [^subscription]} = Postgres.list_ingress_subscriptions(state, enabled.id)
    assert {:error, :invalid_onboarding_id} = Postgres.save_onboarding(state, %{})
  end

  test "runs the release migration task from a selected environment variable" do
    state = start_state()
    env_name = "JIDO_MESSAGING_POSTGRES_TEST_URL_#{System.unique_integer([:positive])}"
    invalid_env_name = env_name <> "_INVALID"
    System.put_env(env_name, database_url())

    System.put_env(invalid_env_name, "not-a-postgresql-url")

    on_exit(fn ->
      System.delete_env(env_name)
      System.delete_env(invalid_env_name)
    end)

    assert :ok = Mix.Tasks.JidoMessaging.Postgres.Migrate.run(["--url-env", env_name])

    assert_raise Mix.Error, ~r/invalid options/, fn ->
      Mix.Tasks.JidoMessaging.Postgres.Migrate.run(["--url", database_url()])
    end

    assert_raise Mix.Error, ~r/is not set/, fn ->
      Mix.Tasks.JidoMessaging.Postgres.Migrate.run(["--url-env", env_name <> "_MISSING"])
    end

    assert_raise Mix.Error, ~r/migration failed: invalid_database_url/, fn ->
      Mix.Tasks.JidoMessaging.Postgres.Migrate.run(["--url-env", invalid_env_name])
    end

    assert {:ok, _result} =
             Postgrex.query(
               state.conn,
               "INSERT INTO jido_messaging_schema_migrations (version, name) VALUES ($1, $2)",
               [0, "unknown"]
             )

    on_exit(fn ->
      Postgrex.query(
        state.conn,
        "DELETE FROM jido_messaging_schema_migrations WHERE version = $1",
        [0]
      )
    end)

    assert_raise Mix.Error, ~r/migration failed: database error/, fn ->
      Mix.Tasks.JidoMessaging.Postgres.Migrate.run(["--url-env", env_name])
    end
  end

  test "emits query telemetry without SQL, parameters, or credentials" do
    state = start_state()
    handler_id = unique_id("postgres-query-telemetry")
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:jido_messaging, :persistence, :query],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:query_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :not_found} = Postgres.get_room(state, unique_id("missing"))

    assert_receive {:query_telemetry, [:jido_messaging, :persistence, :query], measurements, metadata}

    assert is_integer(measurements.duration)
    assert metadata.adapter == Postgres
    assert metadata.instance_id == state.instance_id
    assert metadata.operation == :fetch_record
    assert metadata.result == :ok
    refute Map.has_key?(metadata, :sql)
    refute Map.has_key?(metadata, :params)
    refute Map.has_key?(metadata, :connection_options)
  end

  defp start_state(instance_id \\ unique_id("postgres")) do
    {:ok, state} =
      Postgres.init(
        url: database_url(),
        migrate: true,
        pool_size: 4,
        instance_id: instance_id
      )

    Process.unlink(state.pool)
    on_exit(fn -> cleanup_state(state) end)
    state
  end

  defp cleanup_state(state) do
    delete_instance(state, state.instance_id)
    Postgres.close(state)
  end

  defp delete_instance(state, instance_id) do
    if is_pid(state.pool) and Process.alive?(state.pool) do
      try do
        _result =
          Postgrex.query(
            state.pool,
            "DELETE FROM jido_messaging_records WHERE instance_id = $1",
            [instance_id]
          )
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp message(id) do
    Message.new(%{
      id: id,
      room_id: "room-1",
      sender_id: "sender-1",
      role: :user,
      content: [%{type: :text, text: id}],
      status: :sent,
      inserted_at: DateTime.utc_now()
    })
  end

  defp database_url, do: System.fetch_env!("JIDO_MESSAGING_POSTGRES_URL")

  defp database_url_with_query(query) do
    separator = if String.contains?(database_url(), "?"), do: "&", else: "?"
    database_url() <> separator <> query
  end

  defp database_options do
    uri = URI.parse(database_url())
    [username, password] = String.split(uri.userinfo, ":", parts: 2)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      database: uri.path |> String.trim_leading("/") |> URI.decode(),
      username: URI.decode(username),
      password: URI.decode(password),
      show_sensitive_data_on_connection_error: false
    ]
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
