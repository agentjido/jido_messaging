defmodule JidoMessaging.Demo.ChatAgentRunner do
  @moduledoc """
  Wrapper that runs the ChatAgent within the JidoMessaging AgentRunner framework.

  This module bridges the Jido.AI.ReActAgent with JidoMessaging's agent system by:
  1. Starting the ChatAgent GenServer
  2. Providing a handler function for the AgentRunner
  3. Managing the agent lifecycle

  ## Architecture

      ┌─────────────────┐
      │   AgentRunner   │  <- Subscribes to Signal Bus
      │ (per-room)      │
      └────────┬────────┘
               │ calls handler
               ▼
      ┌─────────────────┐
      │ ChatAgentRunner │  <- Manages ChatAgent lifecycle
      └────────┬────────┘
               │ delegates to
               ▼
      ┌─────────────────┐
      │   ChatAgent     │  <- ReAct reasoning + tools
      │ (GenServer)     │
      └─────────────────┘

  ## Usage

      # Get an agent config for use with AgentRunner
      config = ChatAgentRunner.agent_config()

      # Or start directly
      {:ok, pid} = ChatAgentRunner.start_link(room_id: "demo:lobby", ...)
  """

  use GenServer
  require Logger

  alias JidoMessaging.Demo.ChatAgent

  defstruct [:agent_pid, :room_id, :instance_module]

  @agent_name "ChatAgent"
  # Use :all for demo - responds to every message
  # Use :mention to require @ChatAgent in message text
  @trigger :all

  @doc """
  Returns an agent_config map suitable for use with AgentRunner.

  The handler will delegate to a running ChatAgent instance.
  """
  def agent_config(opts \\ []) do
    %{
      name: Keyword.get(opts, :name, @agent_name),
      trigger: Keyword.get(opts, :trigger, @trigger),
      handler: &handle_message/2
    }
  end

  @doc """
  Start the ChatAgentRunner GenServer.

  This starts both the runner and the underlying ChatAgent.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the ChatAgent pid for direct interaction.
  """
  def get_agent_pid do
    GenServer.call(__MODULE__, :get_agent_pid)
  end

  # Handler function called by AgentRunner

  defp handle_message(message, _context) do
    text = extract_text(message)
    source = message.metadata[:channel] || message.metadata["channel"] || "unknown"

    user =
      message.metadata[:username] || message.metadata["username"] ||
        message.metadata[:display_name] || message.metadata["display_name"] || "unknown"

    prompt = "[#{source} #{user}] #{text}"
    Logger.info("[ChatAgentRunner] Processing: #{prompt}")

    # Get the ChatAgent pid
    case get_agent_pid_safe() do
      {:ok, agent_pid} ->
        case ChatAgent.chat(agent_pid, prompt, timeout: 30_000) do
          {:ok, response} ->
            Logger.info("[ChatAgentRunner] Response: #{response}")
            {:reply, response}

          {:error, reason} ->
            Logger.warning("[ChatAgentRunner] Chat failed: #{inspect(reason)}")
            {:reply, "Sorry, I encountered an error. Please try again."}
        end

      {:error, :not_running} ->
        Logger.warning("[ChatAgentRunner] ChatAgent not running")
        {:reply, "I'm still waking up... try again in a moment!"}
    end
  end

  defp get_agent_pid_safe do
    try do
      {:ok, get_agent_pid()}
    catch
      :exit, _ -> {:error, :not_running}
    end
  end

  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.find_value("", fn
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      %JidoMessaging.Content.Text{text: text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: ""

  # GenServer callbacks

  @impl true
  def init(opts) do
    room_id = Keyword.get(opts, :room_id, "demo:lobby")
    instance_module = Keyword.get(opts, :instance_module, JidoMessaging.Demo.Messaging)
    jido_name = Keyword.get(opts, :jido_name, JidoMessaging.Demo.Jido)

    # Start the ChatAgent GenServer via Jido runtime
    case start_chat_agent(jido_name) do
      {:ok, agent_pid} ->
        Logger.info("[ChatAgentRunner] Started ChatAgent: #{inspect(agent_pid)}")

        state = %__MODULE__{
          agent_pid: agent_pid,
          room_id: room_id,
          instance_module: instance_module
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("[ChatAgentRunner] Failed to start ChatAgent: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_agent_pid, _from, state) do
    {:reply, state.agent_pid, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.agent_pid && Process.alive?(state.agent_pid) do
      GenServer.stop(state.agent_pid, :normal)
    end

    :ok
  end

  defp start_chat_agent(jido_name) do
    # Start the ChatAgent using Jido runtime
    Jido.start_agent(jido_name, ChatAgent)
  end
end
