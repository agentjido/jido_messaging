# Jido Messaging

Messaging and notification system for the Jido ecosystem. Provides a unified interface for building conversational AI agents across multiple channels (Telegram, Discord, Slack, etc.).

## Features

- **Channel-agnostic**: Write once, deploy to any messaging platform
- **OTP-native**: Built on GenServers, Supervisors, and ETS for reliability
- **LLM-ready**: Message format designed for LLM integration with role-based messages
- **Extensible**: Pluggable adapters for storage and channels

## Installation

Add `jido_messaging` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_messaging, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Define Your Messaging Module

```elixir
defmodule MyApp.Messaging do
  use Jido.Messaging,
    adapter: Jido.Messaging.Adapters.ETS
end
```

### 2. Add to Supervision Tree

```elixir
# In application.ex
def start(_type, _args) do
  children = [
    MyApp.Messaging
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### 3. Use the API

```elixir
# Create a room
{:ok, room} = MyApp.Messaging.create_room(%{type: :direct, name: "Support Chat"})

# Save a message
{:ok, message} = MyApp.Messaging.save_message(%{
  room_id: room.id,
  sender_id: "user_123",
  role: :user,
  content: [%Jido.Messaging.Content.Text{text: "Hello!"}]
})

# List messages
{:ok, messages} = MyApp.Messaging.list_messages(room.id)
```

## Adapter Integration (Telegram + Discord)

`jido_messaging` no longer ships in-package Telegram/Discord handlers.  
Use adapter packages directly:

- `jido_chat_telegram` (`Jido.Chat.Telegram.Adapter`)
- `jido_chat_discord` (`Jido.Chat.Discord.Adapter`)

### Dependencies

```elixir
def deps do
  [
    {:jido_messaging, "~> 0.1.0"},
    {:jido_chat_telegram, "~> 0.1.0"},
    {:jido_chat_discord, "~> 0.1.0"}
  ]
end
```

### Runtime Configuration

```elixir
# Telegram
config :jido_chat_telegram,
  telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN")

# Discord (Nostrum transport)
config :nostrum,
  token: System.get_env("DISCORD_BOT_TOKEN")

# Discord webhook verification (optional, recommended)
config :jido_chat_discord,
  discord_public_key: System.get_env("DISCORD_PUBLIC_KEY")
```

### Ingest Wiring Pattern

1. Receive platform payload in your webhook/gateway boundary.
2. Normalize through the adapter package (`Jido.Chat.Telegram.Adapter` or `Jido.Chat.Discord.Adapter`).
3. Pass normalized incoming data into `Jido.Messaging.Ingest.ingest_incoming/4`.
4. Use `Jido.Messaging.AdapterBridge.send_message/4` for outbound delivery.

## Architecture

```
MyApp.Messaging (Supervisor)
├── Runtime (GenServer) - Manages adapter state
└── (Future) RoomSupervisor, InstanceSupervisor

Message Flow:
1. Adapter package receives platform update/webhook/gateway event
2. Transform to normalized incoming struct
3. Ingest: resolve room/participant, persist message
4. Runtime/agent logic processes message
5. Deliver: send reply via adapter bridge
```

## Domain Model

### Message

```elixir
%Jido.Messaging.Message{
  id: "msg_abc123",
  room_id: "room_xyz",
  sender_id: "user_123",
  role: :user | :assistant | :system | :tool,
  content: [%Content.Text{text: "Hello"}],
  status: :sending | :sent | :delivered | :read | :failed,
  metadata: %{}
}
```

### Room

```elixir
%Jido.Messaging.Room{
  id: "room_xyz",
  type: :direct | :group | :channel | :thread,
  name: "Support Chat",
  external_bindings: %{telegram: %{"bot_id" => "chat_123"}}
}
```

### Participant

```elixir
%Jido.Messaging.Participant{
  id: "part_abc",
  type: :human | :agent | :system,
  identity: %{username: "john", display_name: "John"},
  external_ids: %{telegram: "123456789"}
}
```

## Documentation

Full documentation is available at [HexDocs](https://hexdocs.pm/jido_messaging).

## License

This project is licensed under the Apache 2.0 License - see the LICENSE file for details.
