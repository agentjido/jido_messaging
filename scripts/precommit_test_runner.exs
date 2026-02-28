Code.require_file("test/test_helper.exs")

# Keep adapter tests offline by configuring dummy platform tokens.
Application.put_env(:jido_chat_telegram, :telegram_bot_token, "123:abc")
Application.put_env(:jido_chat_discord, :discord_public_key, "dummy-public-key")
Application.put_env(:nostrum, :token, "dummy-discord-token")

{:ok, _} = Application.ensure_all_started(:jido_messaging)

# Default precommit lane: core tests only.
# Set FULL_TEST_SUITE=1 to include integration/story lanes.
ExUnit.configure(exclude: [:flaky])
if System.get_env("FULL_TEST_SUITE") not in ["1", "true", "TRUE", "yes", "on"] do
  ExUnit.configure(exclude: [:flaky, :integration, :story])
end

Path.wildcard("test/**/*_test.exs")
|> Enum.each(&Code.require_file/1)

result = ExUnit.run()
System.halt(if(result.failures == 0, do: 0, else: 1))
