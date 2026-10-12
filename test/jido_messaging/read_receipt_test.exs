defmodule Jido.Messaging.ReadReceiptTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Messaging.Message
  alias Jido.Messaging.Persistence.{ETS, SQLite}

  defmodule NativeAdapter do
    use Jido.Chat.Adapter
    def channel_type, do: :receipt_test
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, Keyword.merge(opts, Map.to_list(opts[:settings] || %{}))}
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])

    def mark_as_read(external_room_id, external_message_id, opts) do
      {:ok, before} = Jido.Messaging.ReadReceiptTest.ETSMessaging.get_message("message-1")
      send(opts[:notify_pid], {:provider_read, external_room_id, external_message_id, opts, before.receipts})
      :ok
    end
  end

  defmodule Resolver do
    @behaviour Jido.Messaging.SecretResolver
    def resolve(:receipt_token, context) do
      send(Application.fetch_env!(Resolver, :notify_pid), {:resolved_secret, context})
      {:ok, "resolved-receipt-token"}
    end

    def resolve(:failing_receipt_token, _context), do: {:error, :unavailable}
  end

  defmodule FailingAdapter do
    use Jido.Chat.Adapter
    def channel_type, do: :receipt_test
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
    def mark_as_read(_room, _message, _opts), do: {:error, :provider_unavailable}
  end

  defmodule UnsupportedAdapter do
    use Jido.Chat.Adapter
    def channel_type, do: :receipt_test
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(binding, _raw), do: Jido.Chat.Delivery.new(binding, "empty", [])
  end

  defmodule FailingPersistence do
    @behaviour Jido.Messaging.Persistence
    for {name, arity} <- ETS.__info__(:functions), {name, arity} != {:mark_message_read, 4} do
      args = Macro.generate_arguments(arity, __MODULE__)
      defdelegate unquote(name)(unquote_splicing(args)), to: ETS
    end

    def mark_message_read(state, id, participant, receipt) do
      if :ets.lookup(state.rooms, :receipt_write_fail) == [],
        do: ETS.mark_message_read(state, id, participant, receipt),
        else: {:error, :store_unavailable}
    end
  end

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.ReadReceiptTest.FailingPersistence, runtime_profile: :core
  end

  describe "provider read mapping" do
    setup do
      start_supervised!(ETSMessaging)

      {:ok, room} =
        ETSMessaging.get_or_create_room_by_external_binding(:receipt_test, "bridge-1", "provider-room-1", %{
          id: "room-1",
          type: :channel,
          name: "Receipt test"
        })

      {:ok, message} =
        ETSMessaging.save_message(%{
          id: "message-1",
          room_id: room.id,
          sender_id: "sender-1",
          role: :user,
          content: [%{type: :text, text: "hello"}],
          external_id: "provider-message-1",
          status: :sent,
          metadata: %{channel: :receipt_test, bridge_id: "bridge-1"}
        })

      {:ok, reader} = ETSMessaging.create_participant(%{id: "reader-1", type: :human})

      {:ok, _} =
        ETSMessaging.create_membership(%{principal_id: reader.id, room_id: room.id, issuer_principal_id: "host"})

      scope = Jido.Messaging.AuthorizationScope.new(%{kind: :room, room_id: room.id, bridge_id: "bridge-1"})

      {:ok, _} =
        ETSMessaging.create_principal_grant(%{
          principal_id: reader.id,
          issuer_principal_id: "host",
          actions: [:receive_message],
          scope: scope
        })

      %{message: message, actor: [principal_id: reader.id, authorization_scope: scope]}
    end

    defp configure(adapter, opts \\ %{}, secret_refs \\ %{}) do
      {:ok, config} =
        ETSMessaging.put_bridge_config(%{id: "bridge-1", adapter_module: adapter, opts: opts, secret_refs: secret_refs})

      result =
        Jido.Messaging.Runtime.ensure_binding(ETSMessaging.__jido_messaging__(:runtime), adapter, "bridge-1",
          bridge_config: config
        )

      {config, result}
    end

    defp read_request(context, id, read_at \\ nil) do
      data = %{
        "request_id" => id,
        "room_id" => context.message.room_id,
        "message_id" => context.message.id,
        "bridge_id" => "bridge-1"
      }

      data = if read_at, do: Map.put(data, "read_at", read_at), else: data
      Jido.Messaging.Signal.MarkAsRead.new!(data)
    end

    test "calls the provider before it persists one stable read receipt", context do
      read_at = ~U[2026-08-20 12:00:00Z]
      {config, {:ok, _}} = configure(NativeAdapter, %{notify_pid: self(), tenant: "tenant-1"})
      {:ok, _} = ETSMessaging.subscribe_signals("jido.messaging.message.read")
      request = read_request(context, "read", DateTime.to_iso8601(read_at))
      assert {:ok, result} = ETSMessaging.execute(request, context.actor)
      assert result.type == "jido.messaging.operation.completed"
      assert_receive {:provider_read, "provider-room-1", "provider-message-1", provider_opts, %{}}
      assert provider_opts[:credentials] == config.credentials
      assert provider_opts[:tenant] == "tenant-1"
      assert {:ok, read} = ETSMessaging.get_message(context.message.id)
      assert read.status == :read
      assert read.receipts["reader-1"].delivered_at == read_at
      assert read.receipts["reader-1"].read_at == read_at

      assert read.receipts["reader-1"].provider_reads["bridge-1"] == %{
               external_message_id: "provider-message-1",
               read_at: read_at
             }

      assert_receive {:signal, fact}
      assert fact.data["participant_id"] == "reader-1"
      assert Jido.Signal.Context.get(fact, "causationid") == request.id

      assert {:ok, _} =
               ETSMessaging.execute(
                 read_request(context, "again", DateTime.to_iso8601(DateTime.add(read_at, 60))),
                 context.actor
               )

      refute_receive {:provider_read, _, _, _, _}
      refute_receive {:signal, _}
      assert {:ok, ^read} = ETSMessaging.get_message(context.message.id)
    end

    test "resolves bridge secrets once before the provider call", context do
      original = Application.get_env(ETSMessaging, :secret_resolver)
      previous_pid = Application.get_env(Resolver, :notify_pid)
      Application.put_env(ETSMessaging, :secret_resolver, Resolver)
      Application.put_env(Resolver, :notify_pid, self())

      on_exit(fn ->
        restore_env(ETSMessaging, :secret_resolver, original)
        restore_env(Resolver, :notify_pid, previous_pid)
      end)

      {_config, {:ok, _}} = configure(NativeAdapter, %{notify_pid: self()}, %{token: :receipt_token})
      assert_receive {:resolved_secret, %{operation: :configure, bridge_id: "bridge-1", adapter_module: NativeAdapter}}
      assert {:ok, _} = ETSMessaging.execute(read_request(context, "read"), context.actor)
      assert_receive {:provider_read, "provider-room-1", "provider-message-1", provider_opts, %{}}
      assert provider_opts[:credentials] == %{token: "resolved-receipt-token"}
      assert {:ok, _} = ETSMessaging.execute(read_request(context, "replay"), context.actor)
      refute_receive {:resolved_secret, _}
    end

    test "does not call or persist when secret resolution fails", context do
      previous = Application.get_env(ETSMessaging, :secret_resolver)
      Application.put_env(ETSMessaging, :secret_resolver, Resolver)
      on_exit(fn -> restore_env(ETSMessaging, :secret_resolver, previous) end)
      {_config, {:error, _}} = configure(NativeAdapter, %{notify_pid: self()}, %{token: :failing_receipt_token})
      assert {:ok, failed} = ETSMessaging.execute(read_request(context, "secret-failed"), context.actor)
      assert failed.data["code"] == "persistence_failed"
      refute_receive {:provider_read, _, _, _, _}
      assert {:ok, unchanged} = ETSMessaging.get_message(context.message.id)
      assert unchanged.receipts == %{}
    end

    test "does not persist a receipt when the provider fails", context do
      {_config, {:ok, _}} = configure(FailingAdapter)
      assert {:ok, failed} = ETSMessaging.execute(read_request(context, "failed"), context.actor)
      assert failed.data["code"] == "provider_failure"
      assert {:ok, unchanged} = ETSMessaging.get_message(context.message.id)
      assert unchanged.status == :sent
      assert unchanged.receipts == %{}
    end

    test "does not claim a receipt for an unsupported adapter", context do
      {_config, {:ok, _}} = configure(UnsupportedAdapter)
      assert {:ok, failed} = ETSMessaging.execute(read_request(context, "unsupported"), context.actor)
      assert failed.data["code"] == "unsupported"
      assert {:ok, unchanged} = ETSMessaging.get_message(context.message.id)
      assert unchanged.status == :sent
      assert unchanged.receipts == %{}
    end

    test "rejects an invalid timestamp before a provider call", context do
      {_config, {:ok, _}} = configure(NativeAdapter, %{notify_pid: self()})

      assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_request}} =
               ETSMessaging.execute(read_request(context, "bad-date", "not-a-date"), context.actor)

      refute_receive {:provider_read, _, _, _, _}
      assert {:ok, unchanged} = ETSMessaging.get_message(context.message.id)
      assert unchanged.receipts == %{}
    end

    test "a receipt store failure cannot repeat the provider operation", context do
      {_config, {:ok, _}} = configure(NativeAdapter, %{notify_pid: self()})
      {_adapter, state} = Jido.Messaging.Runtime.get_persistence(ETSMessaging.__jido_messaging__(:runtime))
      :ets.insert(state.rooms, {:receipt_write_fail, true})
      request = read_request(context, "save-failed")
      assert {:ok, failed} = ETSMessaging.execute(request, context.actor)
      assert failed.data["code"] == "persistence_failed"
      assert_receive {:provider_read, _, _, _, %{}}
      assert {:ok, ^failed} = ETSMessaging.execute(request, context.actor)
      refute_receive {:provider_read, _, _, _, _}
      assert {:ok, unchanged} = ETSMessaging.get_message(context.message.id)
      assert unchanged.receipts == %{}
    end

    test "a disabled bridge cannot use an old captured binding", context do
      {config, {:ok, _}} = configure(NativeAdapter, %{notify_pid: self()})

      assert {:ok, _} =
               ETSMessaging.put_bridge_config(%{
                 id: config.id,
                 adapter_module: NativeAdapter,
                 revision: config.revision,
                 enabled: false,
                 opts: config.opts
               })

      assert {:ok, failed} = ETSMessaging.execute(read_request(context, "disabled"), context.actor)
      assert failed.data["code"] == "persistence_failed"
      refute_receive {:provider_read, _, _, _, _}
      assert {:ok, unchanged} = ETSMessaging.get_message(context.message.id)
      assert unchanged.receipts == %{}
    end

    test "no reader claim can bypass the trusted actor", context do
      {_config, {:ok, _}} = configure(NativeAdapter, %{notify_pid: self()})
      assert {:ok, failed} = ETSMessaging.execute(read_request(context, "no-actor"), [])
      assert failed.data["code"] == "authorization_denied"
      refute_receive {:provider_read, _, _, _, _}
      refute function_exported?(ETSMessaging, :mark_message_as_read, 3)
    end
  end

  describe "persistence parity" do
    test "ETS applies duplicate receipt updates once" do
      {:ok, state} = ETS.init([])
      message = receipt_message("ets-message")
      {:ok, ^message} = ETS.save_message(state, message)

      first = receipt("bridge-1", ~U[2026-08-20 12:00:00Z])
      replay = receipt("bridge-1", ~U[2026-08-20 13:00:00Z])

      assert {:ok, updated, :updated} =
               ETS.mark_message_read(state, message.id, "reader-1", first)

      assert {:ok, ^updated, :unchanged} =
               ETS.mark_message_read(state, message.id, "reader-1", replay)

      assert updated.receipts["reader-1"].read_at == first.read_at
    end

    test "SQLite applies duplicate receipt updates once and keeps them after restart" do
      path = Path.join(System.tmp_dir!(), "jido-messaging-receipt-#{System.unique_integer([:positive])}.sqlite3")
      on_exit(fn -> File.rm(path) end)

      {:ok, state} = SQLite.init(path: path)
      message = receipt_message("sqlite-message")
      {:ok, ^message} = SQLite.save_message(state, message)

      first = receipt("bridge-1", ~U[2026-08-20 12:00:00Z])
      replay = receipt("bridge-1", ~U[2026-08-20 13:00:00Z])

      assert {:ok, updated, :updated} =
               SQLite.mark_message_read(state, message.id, "reader-1", first)

      assert {:ok, ^updated, :unchanged} =
               SQLite.mark_message_read(state, message.id, "reader-1", replay)

      :ok = Sqlite3.close(state.db)
      {:ok, restarted} = SQLite.init(path: path)
      assert {:ok, ^updated} = SQLite.get_message(restarted, message.id)
      :ok = Sqlite3.close(restarted.db)
    end

    test "SQLite keeps receipts isolated when instances use the same message ID" do
      path =
        Path.join(System.tmp_dir!(), "jido-messaging-receipt-isolation-#{System.unique_integer([:positive])}.sqlite3")

      on_exit(fn -> File.rm(path) end)

      {:ok, first_instance} = SQLite.init(path: path, instance_id: "first")
      {:ok, second_instance} = SQLite.init(path: path, instance_id: "second")
      message = receipt_message("shared-message")
      {:ok, ^message} = SQLite.save_message(first_instance, message)
      {:ok, ^message} = SQLite.save_message(second_instance, message)

      first_receipt = receipt("bridge-first", ~U[2026-08-20 12:00:00Z])
      second_receipt = receipt("bridge-second", ~U[2026-08-20 13:00:00Z])

      assert {:ok, first_updated, :updated} =
               SQLite.mark_message_read(first_instance, message.id, "reader-1", first_receipt)

      assert {:ok, second_updated, :updated} =
               SQLite.mark_message_read(second_instance, message.id, "reader-2", second_receipt)

      assert first_updated.receipts == %{"reader-1" => first_updated.receipts["reader-1"]}
      assert second_updated.receipts == %{"reader-2" => second_updated.receipts["reader-2"]}
      assert {:ok, ^first_updated} = SQLite.get_message(first_instance, message.id)
      assert {:ok, ^second_updated} = SQLite.get_message(second_instance, message.id)

      :ok = Sqlite3.close(first_instance.db)
      :ok = Sqlite3.close(second_instance.db)
    end

    test "ETS keeps one receipt during concurrent duplicate updates" do
      {:ok, state} = ETS.init([])
      message = receipt_message("ets-concurrent-message")
      {:ok, ^message} = ETS.save_message(state, message)

      results = concurrent_receipts(ETS, state, message.id)

      assert Enum.count(results, &match?({:ok, _message, :updated}, &1)) == 1
      assert Enum.count(results, &match?({:ok, _message, :unchanged}, &1)) == 7
    end

    test "SQLite keeps one receipt during concurrent duplicate updates" do
      path = Path.join(System.tmp_dir!(), "jido-messaging-receipt-race-#{System.unique_integer([:positive])}.sqlite3")
      on_exit(fn -> File.rm(path) end)

      {:ok, state} = SQLite.init(path: path)
      message = receipt_message("sqlite-concurrent-message")
      {:ok, ^message} = SQLite.save_message(state, message)

      results = concurrent_receipts(SQLite, state, message.id)

      assert Enum.count(results, &match?({:ok, _message, :updated}, &1)) == 1
      assert Enum.count(results, &match?({:ok, _message, :unchanged}, &1)) == 7
      :ok = Sqlite3.close(state.db)
    end
  end

  defp receipt_message(id) do
    Message.new(%{
      id: id,
      room_id: "room-1",
      sender_id: "sender-1",
      role: :user,
      content: [],
      status: :sent
    })
  end

  defp receipt(bridge_id, read_at) do
    %{
      bridge_id: bridge_id,
      external_message_id: "provider-message-1",
      read_at: read_at
    }
  end

  defp concurrent_receipts(persistence, state, message_id) do
    1..8
    |> Task.async_stream(
      fn offset ->
        persistence.mark_message_read(
          state,
          message_id,
          "reader-1",
          receipt("bridge-1", DateTime.add(~U[2026-08-20 12:00:00Z], offset))
        )
      end,
      max_concurrency: 8,
      ordered: false
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
