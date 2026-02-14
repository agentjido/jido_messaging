Code.require_file("test/test_helper.exs")

# Keep Telegram handler tests offline by using HTTPoison for Telegex calls.
Application.put_env(:telegex, :caller_adapter, {HTTPoison, []})
Application.put_env(:telegex, :token, "123:abc")

{:ok, _} = Application.ensure_all_started(:jido_messaging)

ExUnit.configure(exclude: [:flaky])

Path.wildcard("test/**/*_test.exs")
|> Enum.each(&Code.require_file/1)

result = ExUnit.run()
System.halt(if(result.failures == 0, do: 0, else: 1))
