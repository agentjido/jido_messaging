ExUnit.start()

unless Code.ensure_loaded?(Jido.AI.Agent) do
  raise "optional jido_ai integration test requires jido_ai"
end

example_dir = Path.expand("../../examples/jido_ai", __DIR__)
Code.require_file(Path.join(example_dir, "chat_agent.ex"))
Code.require_file(Path.join(example_dir, "chat_agent_runner.ex"))

defmodule Jido.Messaging.OptionalJidoAIIntegrationTest do
  use ExUnit.Case, async: true

  alias Jido.Messaging.Demo.ChatAgent.Actions.{Echo, Help, Time}
  alias Jido.Messaging.Demo.ChatAgentRunner

  test "loads the optional agent and action modules" do
    assert Code.ensure_loaded?(Jido.Messaging.Demo.ChatAgent)
    assert {:ok, %{result: "Echo: hello"}} = Echo.run(%{text: "hello"}, %{})
    assert {:ok, %{result: help}} = Help.run(%{topic: "bridge"}, %{})
    assert help =~ "Bridge"
    assert {:ok, %{result: time}} = Time.run(%{}, %{})
    assert time =~ "UTC"
  end

  test "exposes the example through the core AgentRunner handler contract" do
    config = ChatAgentRunner.agent_config(trigger: :mention)

    assert config.name == "ChatAgent"
    assert config.trigger == :mention
    assert is_function(config.handler, 2)
  end

  test "builds a complete agent demo child specification" do
    assert {:ok, {_flags, children}} =
             Jido.Messaging.Demo.Supervisor.init(
               mode: :agent,
               telegram_chat_id: "telegram-room",
               discord_channel_id: "discord-room"
             )

    agent_runner = Enum.find(children, &(&1.id == Jido.Messaging.AgentRunner))
    assert %{start: {Jido.Messaging.AgentRunner, :start_link, [opts]}} = agent_runner
    assert opts[:room_id] == "demo:lobby"
    assert opts[:thread_id] == "demo:lobby"
  end
end
