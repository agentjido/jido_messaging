defmodule Mix.Tasks.Jido.Messaging.DemoTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Jido.Messaging.Demo

  defmodule A do
    use Jido.Chat.Adapter
    def channel_type, do: :telegram
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(_binding, _input), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    def send_message(_room, _text, _opts), do: raise("Unexpected provider call")
  end

  defmodule B do
    use Jido.Chat.Adapter
    def channel_type, do: :discord
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(_binding, _input), do: Jido.Chat.Signal.Policy.error(:invalid_delivery)
    def send_message(_room, _text, _opts), do: raise("Unexpected provider call")
  end

  @env_keys ~w(TELEGRAM_BOT_TOKEN DISCORD_BOT_TOKEN CEREBRAS_API_KEY TELEGRAM_CHAT_ID DISCORD_CHANNEL_ID JIDO_MESSAGING_DEMO_TELEGRAM_ADAPTER JIDO_MESSAGING_DEMO_DISCORD_ADAPTER)
  @app_keys [
    {:jido_chat_telegram, :telegram_bot_token},
    {:jido_chat_discord, :discord_bot_token},
    {:nostrum, :token},
    {:nostrum, :gateway_intents},
    {:jido_messaging, :demo_telegram_adapter},
    {:jido_messaging, :demo_discord_adapter}
  ]

  setup do
    cwd = File.cwd!()
    directory = Path.join(System.tmp_dir!(), "jido_demo_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.cd!(directory)
    env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    app = Map.new(@app_keys, fn {a, k} = key -> {key, Application.fetch_env(a, k)} end)
    Enum.each(@env_keys, &System.delete_env/1)
    Enum.each(@app_keys, fn {a, k} -> Application.delete_env(a, k) end)
    Application.put_env(:jido_messaging, :demo_telegram_adapter, A)
    Application.put_env(:jido_messaging, :demo_discord_adapter, B)

    on_exit(fn ->
      try do
        if pid = Process.whereis(Jido.Messaging.Demo.Supervisor), do: Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.cd!(cwd)
      File.rm_rf!(directory)
      Enum.each(env, fn {key, value} -> if value, do: System.put_env(key, value), else: System.delete_env(key) end)

      Enum.each(app, fn {{a, k}, value} ->
        case value do
          {:ok, previous} -> Application.put_env(a, k, previous)
          :error -> Application.delete_env(a, k)
        end
      end)
    end)

    %{directory: directory}
  end

  defp fixture_tokens do
    System.put_env("TELEGRAM_BOT_TOKEN", "fixture-telegram-token")
    System.put_env("DISCORD_BOT_TOKEN", "fixture-platform-token")
  end

  defp bridge_state, do: :sys.get_state(Jido.Messaging.Demo.Bridge)

  test "runtime-only startup needs no provider credentials and creates no bridge" do
    assert {:ok, pid} = Demo.start_demo([])
    assert Process.alive?(pid)
    assert Process.whereis(Jido.Messaging.Demo.Messaging.__jido_messaging__(:runtime))
    assert Process.whereis(Jido.Messaging.Demo.Bridge) == nil
    assert System.get_env("TELEGRAM_BOT_TOKEN") == nil
  end

  test "a YAML echo topology starts the runtime and creates its local room" do
    File.write!("echo.yaml", "mode: echo\nrooms:\n  - id: local-room\n    type: group\n    name: Local\n")
    assert {:ok, _} = Demo.start_demo(["--topology", "echo.yaml"])
    assert {:ok, room} = Jido.Messaging.Demo.Messaging.get_room("local-room")
    assert room.name == "Local"
  end

  test "CLI bridge IDs select the fake adapters and preserve the two routes" do
    fixture_tokens()
    assert {:ok, _} = Demo.start_demo(["--bridge", "--telegram-chat", "123", "--discord-channel", "456"])
    state = bridge_state()
    assert Enum.map(state.bindings, &elem(&1, 3)) == ["123", "456"]
    assert Enum.map(state.bindings, &elem(&1, 1)) == [A, B]
  end

  test "dotenv fixtures and environment IDs start the same provider-free bridge" do
    File.write!(
      ".env",
      "TELEGRAM_BOT_TOKEN=fixture-telegram-token\nDISCORD_BOT_TOKEN=fixture-platform-token\nTELEGRAM_CHAT_ID=789\nDISCORD_CHANNEL_ID=987\n"
    )

    assert {:ok, _} = Demo.start_demo(["--bridge"])
    assert Enum.map(bridge_state().bindings, &elem(&1, 3)) == ["789", "987"]
  end

  test "YAML bridge settings retain adapter modules, route IDs and bridge IDs" do
    fixture_tokens()

    File.write!(
      "bridge.yaml",
      "mode: bridge\nbridge:\n  telegram_adapter: #{inspect(A)}\n  discord_adapter: #{inspect(B)}\n  telegram_chat_id: 11\n  discord_channel_id: 22\n  telegram_bridge_id: first\n  discord_bridge_id: second\n"
    )

    assert {:ok, _} = Demo.start_demo(["--topology", "bridge.yaml"])
    state = bridge_state()
    assert Enum.map(state.bindings, &elem(&1, 2)) == ["first", "second"]
    assert Enum.map(state.bindings, &elem(&1, 3)) == ["11", "22"]
  end

  test "missing bridge credentials fail before a supervisor starts" do
    assert_raise Mix.Error, ~r/Missing Telegram bot token/, fn -> Demo.start_demo(["--bridge"]) end
    System.put_env("TELEGRAM_BOT_TOKEN", "fixture-telegram-token")
    assert_raise Mix.Error, ~r/Missing Discord bot token/, fn -> Demo.start_demo(["--bridge"]) end
    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
  end

  test "agent mode rejects a missing model key before agent or provider startup" do
    fixture_tokens()
    assert_raise Mix.Error, ~r/Missing Cerebras API key/, fn -> Demo.start_demo(["--agent"]) end
    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
    assert Process.whereis(Jido.Messaging.Demo.Jido) == nil
  end

  test "missing route IDs fail before bridge startup" do
    fixture_tokens()
    assert_raise Mix.Error, ~r/Missing Telegram chat ID/, fn -> Demo.start_demo(["--bridge"]) end

    assert_raise Mix.Error, ~r/Missing Discord channel ID/, fn ->
      Demo.start_demo(["--bridge", "--telegram-chat", "123"])
    end

    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
  end

  test "missing and non-map topologies fail before runtime startup" do
    assert_raise Mix.Error, ~r/Failed to load topology/, fn -> Demo.start_demo(["--topology", "missing.yaml"]) end
    File.write!("invalid.yaml", "- scalar\n")
    assert_raise Mix.Error, ~r/invalid_topology/, fn -> Demo.start_demo(["--topology", "invalid.yaml"]) end
    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
  end

  test "malformed dotenv content fails before runtime startup" do
    File.write!(".env", "TELEGRAM_BOT_TOKEN='unterminated\n")
    assert_raise Mix.Error, ~r/Failed to load demo environment/, fn -> Demo.start_demo([]) end
    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
  end

  test "an invalid topology application stops its newly started supervisor" do
    File.write!("bad-room.yaml", "mode: echo\nrooms:\n  - name: Missing ID\n")
    assert_raise Mix.Error, ~r/Failed to apply topology/, fn -> Demo.start_demo(["--topology", "bad-room.yaml"]) end
    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
  end

  test "invalid and unavailable adapter configuration fails before bridge startup" do
    fixture_tokens()
    Application.put_env(:jido_messaging, :demo_telegram_adapter, 123)
    assert_raise Mix.Error, ~r/Invalid adapter module configuration/, fn -> Demo.start_demo(["--bridge"]) end
    Application.put_env(:jido_messaging, :demo_telegram_adapter, MissingAdapter)
    assert_raise Mix.Error, ~r/Adapter module not available/, fn -> Demo.start_demo(["--bridge"]) end
    assert Process.whereis(Jido.Messaging.Demo.Supervisor) == nil
  end
end
