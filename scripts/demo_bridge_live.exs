#!/usr/bin/env elixir

workspace_root = Path.expand("../..", __DIR__)
jido_messaging_path = Path.expand("..", __DIR__)

Mix.install([
  {:jido_chat, path: Path.join(workspace_root, "jido_chat")},
  {:jido_chat_telegram, path: Path.join(workspace_root, "jido_chat_telegram")},
  {:jido_chat_discord, path: Path.join(workspace_root, "jido_chat_discord")},
  {:jido_messaging, path: jido_messaging_path}
])

defmodule Jido.Messaging.Demo.EnvSecretResolver do
  @behaviour Jido.Messaging.SecretResolver

  @impl true
  def resolve(environment_variable, _context) when is_binary(environment_variable) do
    System.fetch_env(environment_variable)
  end
end

Application.put_env(
  :jido_messaging,
  :secret_resolver,
  Jido.Messaging.Demo.EnvSecretResolver
)

File.cd!(jido_messaging_path, fn ->
  Mix.Task.run("jido.messaging.demo", ["--topology", "config/demo.topology.live.yaml"])
end)
