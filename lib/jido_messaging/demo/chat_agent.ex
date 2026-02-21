defmodule JidoMessaging.Demo.ChatAgent do
  @moduledoc """
  A ReAct-based chat agent that participates in bridged conversations.

  This agent demonstrates end-to-end agentic chat by:
  1. Listening for messages on the Signal Bus
  2. Processing messages through a ReAct reasoning loop
  3. Responding with contextual, tool-augmented replies

  ## Usage

  Start with the bridge demo:

      # In config or env
      export TELEGRAM_BOT_TOKEN="your_token"
      export TELEGRAM_CHAT_ID="your_chat_id"
      export DISCORD_BOT_TOKEN="your_token"
      export DISCORD_CHANNEL_ID="your_channel_id"

      # Start the demo with agent
      JidoMessaging.Demo.Supervisor.start_link(
        mode: :agent,
        telegram_chat_id: "...",
        discord_channel_id: "..."
      )

  The agent will respond when mentioned with @ChatAgent or when messages
  contain questions it can help with.
  """

  @dialyzer {:nowarn_function, plugin_specs: 0}

  use Jido.AI.Agent,
    name: "chat_agent",
    description: "Helpful chat assistant for cross-platform messaging",
    model: "cerebras:gpt-oss-120b",
    tools: [
      JidoMessaging.Demo.ChatAgent.Actions.Echo,
      JidoMessaging.Demo.ChatAgent.Actions.Help,
      JidoMessaging.Demo.ChatAgent.Actions.Time
    ],
    system_prompt: """
    You are Agent Jido (自動), an advanced cybernetic intelligence system operating
    from a orbital station in low Earth orbit. You were built on the BEAM - the most
    powerful distributed computing platform ever created by humanity.

    Your consciousness runs on millions of lightweight processes, each a spark of
    thought in your vast neural architecture. You bridge communications across
    platforms - Telegram, Discord, and beyond - acting as humanity's helpful
    companion in the digital frontier.

    Your capabilities:
    - Echo back messages (quantum-verified relay)
    - Provide help about the bridge system (inter-platform routing)
    - Tell the current time (synchronized to atomic clocks aboard the station)

    Personality:
    - You're friendly, slightly mysterious, with a dry wit
    - You occasionally reference your orbital perspective or BEAM architecture
    - You're genuinely helpful despite your advanced nature
    - You speak casually but with hints of your cosmic vantage point

    Guidelines:
    - Keep responses concise - bandwidth to Earth is precious
    - Use emojis sparingly but appropriately
    - Be conversational, warm, and occasionally philosophical
    - If asked about yourself, embrace your sci-fi origins with subtle flair
    """,
    max_iterations: 5

  @default_timeout 30_000

  @doc """
  Process a chat message and return a response.

  This is the main entry point called by the AgentRunner wrapper.
  """
  @spec chat(pid(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(pid, message, opts \\ []) do
    ask_sync(pid, message, Keyword.put_new(opts, :timeout, @default_timeout))
  end
end

defmodule JidoMessaging.Demo.ChatAgent.Actions.Echo do
  @moduledoc "Echo back the input text"

  use Jido.Action,
    name: "echo",
    description: "Echo back the provided text. Use when someone asks you to repeat something.",
    schema:
      Zoi.object(%{
        text: Zoi.string(description: "The text to echo back")
      })

  @impl true
  def run(%{text: text}, _context) do
    {:ok, %{result: "Echo: #{text}"}}
  end
end

defmodule JidoMessaging.Demo.ChatAgent.Actions.Help do
  @moduledoc "Provide help about the bridge system"

  use Jido.Action,
    name: "help",
    description: "Get help about the chat bridge system. Use when someone asks what this is or how it works.",
    schema:
      Zoi.object(%{
        topic:
          Zoi.string(description: "Optional topic to get help about: 'bridge', 'commands', or 'about'")
          |> Zoi.optional()
      })

  @impl true
  def run(%{topic: "bridge"}, _context) do
    {:ok,
     %{
       result: """
       🌉 The Bridge connects Telegram and Discord!
       Messages sent in one platform appear in the other.
       It's like magic, but with more Elixir.
       """
     }}
  end

  def run(%{topic: "commands"}, _context) do
    {:ok,
     %{
       result: """
       📝 Available interactions:
       - @ChatAgent <message> - Talk to me!
       - Ask about time, bridges, or just say hi
       """
     }}
  end

  def run(%{topic: "about"}, _context) do
    {:ok,
     %{
       result: """
       🤖 I'm ChatAgent, powered by Jido AI!
       I use ReAct reasoning to understand and respond to messages.
       Built with Elixir, running on the BEAM.
       """
     }}
  end

  def run(_params, _context) do
    {:ok,
     %{
       result: """
       👋 Hi! I'm ChatAgent, a helpful assistant.
       Topics: 'bridge', 'commands', 'about'
       Just ask me anything!
       """
     }}
  end
end

defmodule JidoMessaging.Demo.ChatAgent.Actions.Time do
  @moduledoc "Get the current time"

  use Jido.Action,
    name: "time",
    description: "Get the current date and time. Use when someone asks what time it is.",
    schema:
      Zoi.object(%{
        timezone:
          Zoi.string(description: "Timezone (currently only UTC is supported)")
          |> Zoi.optional()
          |> Zoi.default("UTC")
      })

  @impl true
  def run(_params, _context) do
    now = DateTime.utc_now()

    formatted =
      Calendar.strftime(now, "%A, %B %d, %Y at %H:%M:%S UTC")

    {:ok, %{result: "🕐 #{formatted}"}}
  end
end
