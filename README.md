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
  use JidoMessaging,
    adapter: JidoMessaging.Adapters.ETS
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
  content: [%JidoMessaging.Content.Text{text: "Hello!"}]
})

# List messages
{:ok, messages} = MyApp.Messaging.list_messages(room.id)
```

## Telegram Integration

### Configuration

Configure Telegex in your config:

```elixir
# config/config.exs
config :telegex, caller_adapter: Telegex.Caller.Adapter.Finch

# config/runtime.exs
config :telegex, token: System.get_env("TELEGRAM_BOT_TOKEN")
```

### Create a Telegram Handler

```elixir
defmodule MyApp.TelegramBot do
  use JidoMessaging.Channels.Telegram.Handler,
    messaging: MyApp.Messaging,
    on_message: &MyApp.TelegramBot.handle_message/2

  def handle_message(message, _context) do
    # Echo bot example
    text = hd(message.content).text
    {:reply, "You said: #{text}"}
  end
end
```

### Add to Supervision Tree

```elixir
children = [
  MyApp.Messaging,
  MyApp.TelegramBot
]
```

### Handler Callback Options

The `on_message` callback can return:

- `{:reply, text}` - Send a reply message
- `{:reply, text, opts}` - Send a reply with options (parse_mode, etc.)
- `:noreply` - Don't send a reply
- `{:error, reason}` - Log an error

## Architecture

```
MyApp.Messaging (Supervisor)
├── Runtime (GenServer) - Manages adapter state
└── (Future) RoomSupervisor, InstanceSupervisor

Message Flow:
1. Channel receives update (Telegram getUpdates)
2. Transform to normalized incoming struct
3. Ingest: resolve room/participant, persist message
4. Handler callback processes message
5. Deliver: send reply via channel
```

## Domain Model

### Message

```elixir
%JidoMessaging.Message{
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
%JidoMessaging.Room{
  id: "room_xyz",
  type: :direct | :group | :channel | :thread,
  name: "Support Chat",
  external_bindings: %{telegram: %{"bot_id" => "chat_123"}}
}
```

### Participant

```elixir
%JidoMessaging.Participant{
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
