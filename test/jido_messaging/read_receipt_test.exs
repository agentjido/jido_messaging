defmodule Jido.Messaging.ReadReceiptTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Messaging.Message
  alias Jido.Messaging.Persistence.{ETS, SQLite}

  defmodule NativeAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :receipt_test

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "sent-1"}}

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def mark_as_read(external_room_id, external_message_id, opts) do
      send(opts[:notify_pid], {:provider_read, external_room_id, external_message_id, opts})
      :ok
    end
  end

  defmodule Resolver do
    @behaviour Jido.Messaging.SecretResolver

    @impl true
    def resolve(:receipt_token, context) do
      send(Application.fetch_env!(Resolver, :notify_pid), {:resolved_secret, context})
      {:ok, "resolved-receipt-token"}
    end

    def resolve(:failing_receipt_token, _context), do: {:error, :unavailable}
  end

  defmodule FailingAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :receipt_failure

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "sent-1"}}

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def mark_as_read(_external_room_id, _external_message_id, _opts),
      do: {:error, :provider_unavailable}
  end

  defmodule UnsupportedAdapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :receipt_unsupported

    @impl true
    def send_message(_external_room_id, _text, _opts), do: {:ok, %{message_id: "sent-1"}}

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}
  end

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: ETS
  end

  describe "provider read mapping" do
    setup do
      start_supervised!(ETSMessaging)

      {:ok, room} =
        ETSMessaging.get_or_create_room_by_external_binding(
          :receipt_test,
          "bridge-1",
          "provider-room-1",
          %{id: "room-1", type: :channel, name: "Receipt test"}
        )

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

      %{message: message}
    end

    test "calls the provider before it persists one stable read receipt", %{message: message} do
      read_at = ~U[2026-08-20 12:00:00Z]

      assert {:ok, config} =
               ETSMessaging.put_bridge_config(%{
                 id: "bridge-1",
                 adapter_module: NativeAdapter,
                 opts: %{notify_pid: self(), tenant: "tenant-1"}
               })

      assert {:ok, read} =
               ETSMessaging.mark_message_as_read(message.id, "reader-1", read_at: read_at)

      assert_receive {:provider_read, "provider-room-1", "provider-message-1", provider_opts}
      assert provider_opts[:credentials] == config.credentials
      assert provider_opts[:tenant] == "tenant-1"
      assert provider_opts[:participant_id] == "reader-1"

      assert read.status == :read
      assert read.receipts["reader-1"].delivered_at == read_at
      assert read.receipts["reader-1"].read_at == read_at

      assert read.receipts["reader-1"].provider_reads["bridge-1"] == %{
               external_message_id: "provider-message-1",
               read_at: read_at
             }

      assert {:ok, replayed} =
               ETSMessaging.mark_message_as_read(message.id, "reader-1", read_at: DateTime.add(read_at, 60))

      assert replayed == read
      refute_receive {:provider_read, _, _, _}
      assert {:ok, ^read} = ETSMessaging.get_message(message.id)
    end

    test "resolves bridge secrets for mark_as_read before calling the provider", %{message: message} do
      original_resolver = Application.get_env(ETSMessaging, :secret_resolver)
      original_notify_pid = Application.get_env(Resolver, :notify_pid)
      Application.put_env(ETSMessaging, :secret_resolver, Resolver)
      Application.put_env(Resolver, :notify_pid, self())

      on_exit(fn ->
        restore_env(ETSMessaging, :secret_resolver, original_resolver)
        restore_env(Resolver, :notify_pid, original_notify_pid)
      end)

      assert {:ok, _config} =
               ETSMessaging.put_bridge_config(%{
                 id: "bridge-1",
                 adapter_module: NativeAdapter,
                 secret_refs: %{token: :receipt_token},
                 opts: %{notify_pid: self()}
               })

      assert {:ok, _read} = ETSMessaging.mark_message_as_read(message.id, "reader-1")

      assert_receive {:resolved_secret,
                      %{operation: :mark_as_read, bridge_id: "bridge-1", adapter_module: NativeAdapter}}

      assert_receive {:provider_read, "provider-room-1", "provider-message-1", provider_opts}
      assert provider_opts[:credentials] == %{token: "resolved-receipt-token"}
      assert provider_opts[:participant_id] == "reader-1"
      assert provider_opts[:local_message_id] == message.id
    end

    test "does not call the provider or persist when secret resolution fails", %{message: message} do
      original_resolver = Application.get_env(ETSMessaging, :secret_resolver)
      Application.put_env(ETSMessaging, :secret_resolver, Resolver)
      on_exit(fn -> restore_env(ETSMessaging, :secret_resolver, original_resolver) end)

      assert {:ok, _config} =
               ETSMessaging.put_bridge_config(%{
                 id: "bridge-1",
                 adapter_module: NativeAdapter,
                 secret_refs: %{token: :failing_receipt_token},
                 opts: %{notify_pid: self()}
               })

      assert {:error, {:secret_resolution_failed, "bridge-1", :token, :resolver_failed}} =
               ETSMessaging.mark_message_as_read(message.id, "reader-1")

      refute_receive {:provider_read, _, _, _}
      assert {:ok, unchanged} = ETSMessaging.get_message(message.id)
      assert unchanged.receipts == %{}
    end

    test "does not persist a receipt when the provider fails", %{message: message} do
      assert {:ok, _config} =
               ETSMessaging.put_bridge_config(%{
                 id: "bridge-1",
                 adapter_module: FailingAdapter
               })

      assert {:error, :provider_unavailable} =
               ETSMessaging.mark_message_as_read(message.id, "reader-1")

      assert {:ok, unchanged} = ETSMessaging.get_message(message.id)
      assert unchanged.status == :sent
      assert unchanged.receipts == %{}
    end

    test "does not claim a receipt for an unsupported adapter", %{message: message} do
      assert {:ok, _config} =
               ETSMessaging.put_bridge_config(%{
                 id: "bridge-1",
                 adapter_module: UnsupportedAdapter
               })

      assert {:error, :unsupported} =
               ETSMessaging.mark_message_as_read(message.id, "reader-1")

      assert {:ok, unchanged} = ETSMessaging.get_message(message.id)
      assert unchanged.status == :sent
      assert unchanged.receipts == %{}
    end

    test "rejects an invalid timestamp before it calls the provider", %{message: message} do
      assert {:ok, _config} =
               ETSMessaging.put_bridge_config(%{
                 id: "bridge-1",
                 adapter_module: NativeAdapter,
                 opts: %{notify_pid: self()}
               })

      assert {:error, :invalid_read_at} =
               ETSMessaging.mark_message_as_read(message.id, "reader-1", read_at: "not-a-date")

      refute_receive {:provider_read, _, _, _}
      assert {:ok, unchanged} = ETSMessaging.get_message(message.id)
      assert unchanged.receipts == %{}
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
