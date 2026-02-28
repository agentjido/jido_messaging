#!/usr/bin/env elixir

workspace_root = Path.expand("../..", __DIR__)
jido_messaging_path = Path.expand("..", __DIR__)

Mix.install([
  {:jido_chat, path: Path.join(workspace_root, "jido_chat")},
  {:jido_chat_telegram, path: Path.join(workspace_root, "jido_chat_telegram")},
  {:jido_chat_discord, path: Path.join(workspace_root, "jido_chat_discord")},
  {:jido_messaging, path: jido_messaging_path}
])

File.cd!(jido_messaging_path, fn ->
  Mix.Task.run("jido.messaging.demo", ["--topology", "config/demo.topology.live.yaml"])
end)
