# Test script for ChatAgent with Cerebras
#
# Usage:
#   CEREBRAS_API_KEY=your_key mix run scripts/test_chat_agent.exs
#
# Or set the key in your .env file

alias JidoMessaging.Demo.ChatAgent

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("ChatAgent Test Script (Cerebras)")
IO.puts(String.duplicate("=", 60))

# Check for API key
api_key = System.get_env("CEREBRAS_API_KEY")

unless api_key do
  IO.puts("\n❌ CEREBRAS_API_KEY not set!")
  IO.puts("   Set it with: export CEREBRAS_API_KEY=your_key")
  System.halt(1)
end

IO.puts("\n✅ CEREBRAS_API_KEY is set")

# Start Jido runtime and the ChatAgent
{:ok, _jido} = Jido.start_link(name: ChatAgentTest.Jido)
{:ok, pid} = Jido.start_agent(ChatAgentTest.Jido, ChatAgent)

IO.puts("✅ ChatAgent started: #{inspect(pid)}")

# Test queries
queries = [
  "What time is it?",
  "Help me understand what you can do",
  "Echo: Hello from the test script!"
]

for {query, i} <- Enum.with_index(queries, 1) do
  IO.puts("\n" <> String.duplicate("-", 50))
  IO.puts("[Query #{i}] #{query}")
  IO.puts(String.duplicate("-", 50))

  case ChatAgent.ask_sync(pid, query, timeout: 30_000) do
    {:ok, response} ->
      IO.puts("✅ Response:\n#{response}")

    {:error, reason} ->
      IO.puts("❌ Error: #{inspect(reason)}")
  end
end

GenServer.stop(pid)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Test complete!")
IO.puts(String.duplicate("=", 60) <> "\n")
