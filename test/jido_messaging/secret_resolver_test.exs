defmodule Jido.Messaging.SecretResolverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Messaging.OutboundGateway

  @marker "secret-marker-do-not-persist"

  defmodule Resolver do
    @behaviour Jido.Messaging.SecretResolver

    @impl true
    def resolve(:failing_reference, _context) do
      {:error, {:provider_failure, "secret-marker-do-not-persist"}}
    end

    def resolve(reference, _context) do
      Application.fetch_env(__MODULE__, reference)
    end
  end

  defmodule Adapter do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :secret_test

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, text, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:adapter_credentials, text, Keyword.fetch!(opts, :credentials)})
      end

      {:ok, %{message_id: "secret-test-#{text}"}}
    end
  end

  defmodule ETSMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  defmodule SQLiteMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.SQLite
  end

  setup do
    original_ets_resolver = Application.get_env(ETSMessaging, :secret_resolver)
    original_sqlite_resolver = Application.get_env(SQLiteMessaging, :secret_resolver)
    original_secret = Application.get_env(Resolver, :telegram_token)

    Application.put_env(ETSMessaging, :secret_resolver, Resolver)
    Application.put_env(SQLiteMessaging, :secret_resolver, Resolver)

    on_exit(fn ->
      restore_env(ETSMessaging, :secret_resolver, original_ets_resolver)
      restore_env(SQLiteMessaging, :secret_resolver, original_sqlite_resolver)
      restore_env(Resolver, :telegram_token, original_secret)
    end)

    :ok
  end

  test "resolves secrets for each outbound operation and observes rotation" do
    start_supervised!(ETSMessaging)
    Application.put_env(Resolver, :telegram_token, @marker)

    assert {:ok, stored} =
             ETSMessaging.put_bridge_config(%{
               id: "secret-rotation",
               adapter_module: Adapter,
               secret_refs: %{token: :telegram_token}
             })

    assert stored.credentials == %{}
    assert stored.secret_refs == %{token: :telegram_token}
    refute inspect(stored) =~ @marker

    context = %{channel: Adapter, bridge_id: stored.id, external_room_id: "room-1"}

    assert {:ok, _result} =
             OutboundGateway.send_message(ETSMessaging, context, "first", test_pid: self())

    assert_receive {:adapter_credentials, "first", %{token: @marker}}

    rotated = "rotated-secret-marker"
    Application.put_env(Resolver, :telegram_token, rotated)

    assert {:ok, _result} =
             OutboundGateway.send_message(ETSMessaging, context, "second", test_pid: self())

    assert_receive {:adapter_credentials, "second", %{token: ^rotated}}

    assert {:ok, fetched} = ETSMessaging.get_bridge_config(stored.id)
    assert fetched.secret_refs == stored.secret_refs
    assert fetched.credentials == %{}
  end

  test "rejects raw bridge credentials" do
    start_supervised!(ETSMessaging)

    assert {:error, :raw_bridge_credentials_not_allowed} =
             ETSMessaging.put_bridge_config(%{
               id: "raw-secret",
               adapter_module: Adapter,
               credentials: %{token: @marker}
             })
  end

  test "classifies resolver failures without diagnostic secret values" do
    start_supervised!(ETSMessaging)

    assert {:ok, stored} =
             ETSMessaging.put_bridge_config(%{
               id: "secret-failure",
               adapter_module: Adapter,
               secret_refs: %{token: :failing_reference}
             })

    context = %{channel: Adapter, bridge_id: stored.id, external_room_id: "room-1"}

    log =
      capture_log(fn ->
        assert {:error, error} =
                 OutboundGateway.send_message(ETSMessaging, context, "failure", test_pid: self())

        assert error.reason ==
                 {:secret_resolution_failed, "secret-failure", :token, :resolver_failed}

        assert error.category == :terminal
        refute inspect(error) =~ @marker
      end)

    refute log =~ @marker
  end

  test "SQLite stores references without resolved marker values" do
    path = Path.join(System.tmp_dir!(), "jido-messaging-secrets-#{System.unique_integer([:positive])}.sqlite3")
    File.rm(path)

    start_supervised!({SQLiteMessaging, persistence_opts: [path: path]})
    Application.put_env(Resolver, :telegram_token, @marker)

    assert {:ok, stored} =
             SQLiteMessaging.put_bridge_config(%{
               id: "sqlite-secret",
               adapter_module: Adapter,
               secret_refs: %{token: :telegram_token}
             })

    bytes = path |> then(&Path.wildcard("#{&1}*")) |> Enum.map_join(&File.read!/1)
    assert :binary.match(bytes, "telegram_token") != :nomatch
    assert :binary.match(bytes, @marker) == :nomatch
    refute inspect(stored) =~ @marker

    on_exit(fn -> File.rm(path) end)
  end

  defp restore_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_env(application, key, value), do: Application.put_env(application, key, value)
end
