defmodule Jido.Messaging.Demo.Supervisor do
  @moduledoc """
  Supervisor for the demo messaging service.

  Supports three modes:
  - Echo mode: messaging runtime only
  - Bridge mode: signal-driven Telegram <-> Discord bridge
  - Agent mode: bridge + ReAct ChatAgent that responds to mentions

  ## Agent Mode

  In agent mode, a ChatAgent powered by Jido.AI ReAct joins the bridged chat.
  Mention @ChatAgent to interact with it:

      @ChatAgent what time is it?
      @ChatAgent help
      @ChatAgent tell me about the bridge

  ## Usage

      # Echo mode (default)
      Jido.Messaging.Demo.Supervisor.start_link()

      # Bridge mode
      Jido.Messaging.Demo.Supervisor.start_link(
        mode: :bridge,
        telegram_chat_id: "123456",
        discord_channel_id: "789012"
      )

      # Agent mode (bridge + ChatAgent)
      Jido.Messaging.Demo.Supervisor.start_link(
        mode: :agent,
        telegram_chat_id: "123456",
        discord_channel_id: "789012"
      )
  """
  use Supervisor

  require Logger

  alias Jido.Messaging.Demo.ChatAgentRunner

  @shared_room_id "demo:lobby"

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    mode = Keyword.get(opts, :mode, :echo)
    telegram_chat_id = Keyword.get(opts, :telegram_chat_id)
    discord_channel_id = Keyword.get(opts, :discord_channel_id)
    telegram_adapter = Keyword.get(opts, :telegram_adapter)
    discord_adapter = Keyword.get(opts, :discord_adapter)
    telegram_bridge_id = Keyword.get(opts, :telegram_bridge_id)
    discord_bridge_id = Keyword.get(opts, :discord_bridge_id)

    children =
      build_children(
        mode,
        telegram_chat_id,
        discord_channel_id,
        telegram_adapter,
        discord_adapter,
        telegram_bridge_id,
        discord_bridge_id
      )

    Logger.info("[Demo] Starting supervisor in #{mode} mode")

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children(
         :echo,
         _telegram_chat_id,
         _discord_channel_id,
         _telegram_adapter,
         _discord_adapter,
         _telegram_bridge_id,
         _discord_bridge_id
       ) do
    [
      Jido.Messaging.Demo.Messaging
    ]
  end

  defp build_children(
         :bridge,
         telegram_chat_id,
         discord_channel_id,
         telegram_adapter,
         discord_adapter,
         telegram_bridge_id,
         discord_bridge_id
       ) do
    [
      Jido.Messaging.Demo.Messaging,
      {Jido.Messaging.Demo.Bridge,
       instance_module: Jido.Messaging.Demo.Messaging,
       telegram_chat_id: telegram_chat_id,
       discord_channel_id: discord_channel_id,
       telegram_adapter: telegram_adapter,
       discord_adapter: discord_adapter,
       telegram_bridge_id: telegram_bridge_id,
       discord_bridge_id: discord_bridge_id}
    ]
  end

  defp build_children(
         :agent,
         telegram_chat_id,
         discord_channel_id,
         telegram_adapter,
         discord_adapter,
         telegram_bridge_id,
         discord_bridge_id
       ) do
    # Start bridge components first, then add the ChatAgent
    bridge_children =
      build_children(
        :bridge,
        telegram_chat_id,
        discord_channel_id,
        telegram_adapter,
        discord_adapter,
        telegram_bridge_id,
        discord_bridge_id
      )

    agent_children = [
      # ChatAgentRunner manages the ChatAgent lifecycle
      {ChatAgentRunner, room_id: @shared_room_id, instance_module: Jido.Messaging.Demo.Messaging},

      # AgentRunner connects the ChatAgent to the messaging system
      {Jido.Messaging.AgentRunner,
       room_id: @shared_room_id,
       agent_id: "chat_agent",
       agent_config: ChatAgentRunner.agent_config(),
       instance_module: Jido.Messaging.Demo.Messaging},

      # HeartbeatSensor sends periodic messages every minute
      {Jido.Sensor.Runtime,
       sensor: Jido.Messaging.Demo.HeartbeatSensor,
       config: %{
         interval: 60_000,
         room_id: @shared_room_id,
         instance_module: Jido.Messaging.Demo.Messaging
       },
       id: :heartbeat_sensor}
    ]

    bridge_children ++ agent_children
  end
end
