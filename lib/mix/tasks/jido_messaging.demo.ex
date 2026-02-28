defmodule Mix.Tasks.Jido.Messaging.Demo do
  @shortdoc "Runs a demo messaging service (echo, bridge, or agent mode)"
  @moduledoc """
  Starts a demo messaging service.

  ## Usage

  Echo mode (Telegram only):

      mix jido_messaging.demo

  Bridge mode (Telegram <-> Discord):

      mix jido_messaging.demo --bridge --telegram-chat 123456 --discord-channel 789012

  Agent mode (Bridge + ChatAgent):

      mix jido_messaging.demo --agent --telegram-chat 123456 --discord-channel 789012

  YAML topology mode:

      mix jido_messaging.demo --topology config/demo.topology.yaml

  ## Configuration

  Create a `.env` file in the project root:

      TELEGRAM_BOT_TOKEN=your_telegram_token
      DISCORD_BOT_TOKEN=your_discord_token
      CEREBRAS_API_KEY=your_cerebras_key  # Required for agent mode

  ## Options

  - `--bridge` - Enable bridge mode (requires Discord)
  - `--agent` - Enable agent mode (bridge + ChatAgent, requires Cerebras API key)
  - `--telegram-chat ID` - Telegram chat ID to bridge
  - `--discord-channel ID` - Discord channel ID to bridge
  - `--topology PATH` - YAML topology bootstrap file

  ## What it does

  **Echo mode**: Telegram bot echoes back messages (default)

  **Bridge mode**: Messages sent in Telegram appear in Discord and vice versa:
  - Telegram message "hello" -> Discord shows "[TG @user] hello"
  - Discord message "hey" -> Telegram shows "[DC user] hey"

  **Agent mode**: Bridge + a ReAct ChatAgent that responds when mentioned:
  - Mention @ChatAgent in either platform to chat with the AI
  - Agent responses are bridged to both platforms

  Press Ctrl+C twice to stop.
  """
  use Mix.Task

  require Logger

  alias Jido.Messaging.Demo.Topology

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          bridge: :boolean,
          agent: :boolean,
          topology: :string,
          telegram_chat: :integer,
          discord_channel: :integer
        ],
        aliases: [b: :bridge, a: :agent]
      )

    load_dotenv()
    topology = maybe_load_topology!(opts[:topology])

    mode = resolve_mode(opts, topology)

    validate_config!(mode)
    adapter_modules = resolve_adapter_modules(mode, topology)
    configure_adapters!(adapter_modules)

    Logger.info("[Demo] Starting Jido.Messaging Demo (#{mode} mode)")
    Logger.info("[Demo] Press Ctrl+C twice to stop")

    start_applications!(mode, adapter_modules)

    supervisor_opts =
      case mode do
        :echo ->
          [mode: :echo]

        :bridge ->
          telegram_chat_id = resolve_telegram_chat_id(opts, topology)
          discord_channel_id = resolve_discord_channel_id(opts, topology)
          [telegram_adapter, discord_adapter] = adapter_modules

          [
            mode: :bridge,
            telegram_chat_id: telegram_chat_id,
            discord_channel_id: discord_channel_id,
            telegram_adapter: telegram_adapter,
            discord_adapter: discord_adapter
          ]

        :agent ->
          telegram_chat_id = resolve_telegram_chat_id(opts, topology)
          discord_channel_id = resolve_discord_channel_id(opts, topology)
          [telegram_adapter, discord_adapter] = adapter_modules

          [
            mode: :agent,
            telegram_chat_id: telegram_chat_id,
            discord_channel_id: discord_channel_id,
            telegram_adapter: telegram_adapter,
            discord_adapter: discord_adapter
          ]
      end

    # Start Jido runtime for agent mode
    if mode == :agent do
      {:ok, _jido} = Jido.start_link(name: Jido.Messaging.Demo.Jido)
      Logger.info("[Demo] Started Jido runtime for ChatAgent")
    end

    {:ok, _pid} = Jido.Messaging.Demo.Supervisor.start_link(supervisor_opts)
    apply_topology!(topology)

    Process.sleep(:infinity)
  end

  defp maybe_load_topology!(nil), do: nil
  defp maybe_load_topology!(""), do: nil

  defp maybe_load_topology!(path) when is_binary(path) do
    case Topology.load(path) do
      {:ok, topology} ->
        Logger.info("[Demo] Loaded topology: #{path}")
        topology

      {:error, reason} ->
        Mix.raise("Failed to load topology #{path}: #{inspect(reason)}")
    end
  end

  defp resolve_mode(opts, nil) do
    cond do
      opts[:agent] -> :agent
      opts[:bridge] -> :bridge
      true -> :echo
    end
  end

  defp resolve_mode(opts, topology) do
    cond do
      opts[:agent] -> :agent
      opts[:bridge] -> :bridge
      true -> Topology.mode(topology) || :echo
    end
  end

  defp load_dotenv do
    env_file = Path.join(File.cwd!(), ".env")

    if File.exists?(env_file) do
      Dotenvy.source!([env_file])
      Logger.info("[Demo] Loaded .env file")
    end

    :ok
  end

  defp validate_config!(:echo) do
    validate_telegram_token!()
  end

  defp validate_config!(:bridge) do
    validate_telegram_token!()
    validate_discord_token!()
  end

  defp validate_config!(:agent) do
    validate_telegram_token!()
    validate_discord_token!()
    validate_cerebras_key!()
  end

  defp validate_telegram_token! do
    token =
      Dotenvy.env!("TELEGRAM_BOT_TOKEN", :string, default: nil) ||
        Application.get_env(:jido_chat_telegram, :telegram_bot_token)

    unless token do
      Mix.raise("""
      Missing Telegram bot token!

      Add to .env:

          TELEGRAM_BOT_TOKEN=your_token

      Get a token from @BotFather on Telegram.
      """)
    end

    Application.put_env(:jido_chat_telegram, :telegram_bot_token, token)
  end

  defp validate_discord_token! do
    token =
      Dotenvy.env!("DISCORD_BOT_TOKEN", :string, default: nil) ||
        Application.get_env(:nostrum, :token)

    unless token do
      Mix.raise("""
      Missing Discord bot token!

      Add to .env:

          DISCORD_BOT_TOKEN=your_token

      Get a token from Discord Developer Portal.
      """)
    end

    Application.put_env(:nostrum, :token, token)
    Application.put_env(:jido_chat_discord, :discord_bot_token, token)
  end

  defp validate_cerebras_key! do
    key = Dotenvy.env!("CEREBRAS_API_KEY", :string, default: nil)

    unless key do
      Mix.raise("""
      Missing Cerebras API key for agent mode!

      Add to .env:

          CEREBRAS_API_KEY=your_key

      Get a key from Cerebras Cloud.
      """)
    end
  end

  defp resolve_adapter_modules(:echo, _topology), do: []

  defp resolve_adapter_modules(mode, topology) when mode in [:bridge, :agent] do
    telegram_adapter =
      Topology.adapter_module(topology || %{}, "telegram_adapter") ||
        resolve_adapter_module(
          :demo_telegram_adapter,
          "JIDO_MESSAGING_DEMO_TELEGRAM_ADAPTER",
          "Elixir.Jido.Chat.Telegram.Adapter"
        )

    discord_adapter =
      Topology.adapter_module(topology || %{}, "discord_adapter") ||
        resolve_adapter_module(
          :demo_discord_adapter,
          "JIDO_MESSAGING_DEMO_DISCORD_ADAPTER",
          "Elixir.Jido.Chat.Discord.Adapter"
        )

    [telegram_adapter, discord_adapter]
  end

  defp resolve_telegram_chat_id(opts, topology) do
    opts[:telegram_chat] ||
      Topology.bridge_value(topology || %{}, "telegram_chat_id") ||
      get_telegram_chat_id()
  end

  defp resolve_discord_channel_id(opts, topology) do
    opts[:discord_channel] ||
      Topology.bridge_value(topology || %{}, "discord_channel_id") ||
      get_discord_channel_id()
  end

  defp resolve_adapter_module(config_key, env_key, default_module_name) do
    configured =
      Application.get_env(:jido_messaging, config_key) ||
        Dotenvy.env!(env_key, :string, default: default_module_name)

    case configured do
      module when is_atom(module) ->
        module

      module_name when is_binary(module_name) and module_name != "" ->
        module_name
        |> String.split(".")
        |> Module.concat()

      other ->
        Mix.raise("Invalid adapter module configuration for #{config_key}: #{inspect(other)}")
    end
  end

  defp configure_adapters!([]), do: :ok

  defp configure_adapters!(adapter_modules) when is_list(adapter_modules) do
    if Enum.any?(adapter_modules, &(to_string(&1) =~ "Discord")) do
      Application.put_env(:nostrum, :gateway_intents, [
        :guilds,
        :guild_messages,
        :message_content,
        :direct_messages
      ])
    end

    :ok
  end

  defp start_applications!(:echo, _adapter_modules) do
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:jido_signal)
  end

  defp start_applications!(:bridge, adapter_modules) do
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:jido_signal)
    Enum.each(adapter_modules, &ensure_adapter_application_started!/1)
  end

  defp start_applications!(:agent, adapter_modules) do
    start_applications!(:bridge, adapter_modules)
    Application.ensure_all_started(:jido)
    Application.ensure_all_started(:jido_ai)
  end

  defp ensure_adapter_application_started!(adapter_module) do
    if Code.ensure_loaded?(adapter_module) do
      case Application.get_application(adapter_module) do
        nil ->
          :ok

        app ->
          Application.ensure_all_started(app)
      end
    else
      Mix.raise("""
      Adapter module not available: #{inspect(adapter_module)}

      Ensure the adapter package is added to your host application's deps,
      then run `mix deps.get`.
      """)
    end
  end

  defp get_telegram_chat_id do
    case Dotenvy.env!("TELEGRAM_CHAT_ID", :integer, default: nil) do
      nil ->
        Mix.raise("""
        Missing Telegram chat ID for bridge mode!

        Add to .env:

            TELEGRAM_CHAT_ID=123456789

        Or pass via command line:

            mix jido_messaging.demo --bridge --telegram-chat 123456789
        """)

      id ->
        id
    end
  end

  defp get_discord_channel_id do
    case Dotenvy.env!("DISCORD_CHANNEL_ID", :integer, default: nil) do
      nil ->
        Mix.raise("""
        Missing Discord channel ID for bridge mode!

        Add to .env:

            DISCORD_CHANNEL_ID=123456789012345678

        Or pass via command line:

            mix jido_messaging.demo --bridge --discord-channel 123456789012345678
        """)

      id ->
        id
    end
  end

  defp apply_topology!(nil), do: :ok

  defp apply_topology!(topology) when is_map(topology) do
    case Topology.apply(Jido.Messaging.Demo.Messaging, topology) do
      {:ok, summary} ->
        Logger.info("[Demo] Applied topology: #{inspect(summary)}")
        :ok

      {:error, reason} ->
        Mix.raise("Failed to apply topology: #{inspect(reason)}")
    end
  end
end
