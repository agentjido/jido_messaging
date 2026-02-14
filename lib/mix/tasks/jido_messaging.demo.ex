defmodule Mix.Tasks.JidoMessaging.Demo do
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

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          bridge: :boolean,
          agent: :boolean,
          telegram_chat: :integer,
          discord_channel: :integer
        ],
        aliases: [b: :bridge, a: :agent]
      )

    load_dotenv()

    mode =
      cond do
        opts[:agent] -> :agent
        opts[:bridge] -> :bridge
        true -> :echo
      end

    validate_config!(mode)
    configure_adapters!(mode)

    Logger.info("[Demo] Starting JidoMessaging Demo (#{mode} mode)")
    Logger.info("[Demo] Press Ctrl+C twice to stop")

    start_applications!(mode)

    supervisor_opts =
      case mode do
        :echo ->
          [mode: :echo]

        :bridge ->
          telegram_chat_id = opts[:telegram_chat] || get_telegram_chat_id()
          discord_channel_id = opts[:discord_channel] || get_discord_channel_id()

          [
            mode: :bridge,
            telegram_chat_id: telegram_chat_id,
            discord_channel_id: discord_channel_id
          ]

        :agent ->
          telegram_chat_id = opts[:telegram_chat] || get_telegram_chat_id()
          discord_channel_id = opts[:discord_channel] || get_discord_channel_id()

          [
            mode: :agent,
            telegram_chat_id: telegram_chat_id,
            discord_channel_id: discord_channel_id
          ]
      end

    # Start Jido runtime for agent mode
    if mode == :agent do
      {:ok, _jido} = Jido.start_link(name: JidoMessaging.Demo.Jido)
      Logger.info("[Demo] Started Jido runtime for ChatAgent")
    end

    {:ok, _pid} = JidoMessaging.Demo.Supervisor.start_link(supervisor_opts)

    Process.sleep(:infinity)
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
        Application.get_env(:telegex, :token)

    unless token do
      Mix.raise("""
      Missing Telegram bot token!

      Add to .env:

          TELEGRAM_BOT_TOKEN=your_token

      Get a token from @BotFather on Telegram.
      """)
    end

    Application.put_env(:telegex, :token, token)
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

  defp configure_adapters!(:echo) do
    Application.put_env(:telegex, :caller_adapter, {Finch, []})
  end

  defp configure_adapters!(:bridge) do
    Application.put_env(:telegex, :caller_adapter, {Finch, []})

    Application.put_env(:nostrum, :gateway_intents, [
      :guilds,
      :guild_messages,
      :message_content,
      :direct_messages
    ])
  end

  defp configure_adapters!(:agent) do
    configure_adapters!(:bridge)
  end

  defp start_applications!(:echo) do
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:jido_signal)
    Application.ensure_all_started(:finch)
    Application.ensure_all_started(:telegex)
  end

  defp start_applications!(:bridge) do
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:jido_signal)
    Application.ensure_all_started(:finch)
    Application.ensure_all_started(:telegex)
    Application.ensure_all_started(:nostrum)
  end

  defp start_applications!(:agent) do
    start_applications!(:bridge)
    Application.ensure_all_started(:jido)
    Application.ensure_all_started(:jido_ai)
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
end
