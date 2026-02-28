# Jido Messaging

Messaging and notification system for the Jido ecosystem. Provides a unified interface for building conversational AI agents across multiple channels (Telegram, Discord, Slack, etc.).

## Experimental Status

This package is experimental and pre-1.0. APIs and behavior will change.
`jido_messaging` is built around `Jido.Chat` and the Elixir implementation
aligned to the Vercel Chat SDK ([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

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
    {:jido_messaging, github: "agentjido/jido_messaging", branch: "main"}
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
    {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
    {:jido_chat_telegram, github: "agentjido/jido_chat_telegram", branch: "main"},
    {:jido_chat_discord, github: "agentjido/jido_chat_discord", branch: "main"},
    {:jido_messaging, github: "agentjido/jido_messaging", branch: "main"}
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

### Ingress Wiring Pattern

`jido_messaging` is now the shared ingress runtime:

1. Host app receives webhook/gateway payload.
2. Call `MyApp.Messaging.route_webhook_request/4` or `route_payload/3`.
3. Runtime resolves bridge config, verifies/parses via adapter callbacks, and routes through `Jido.Chat.process_event/4`.
4. Message events are ingested; non-message events return typed envelopes.

Canonical APIs:

- `MyApp.Messaging.route_webhook_request(bridge_id, request_meta, payload, opts \\ [])`
- `MyApp.Messaging.route_payload(bridge_id, payload, opts \\ [])`
- `Jido.Messaging.WebhookPlug` (generic host-mounted Plug endpoint)
- `MyApp.Messaging.create_bridge_room(spec)` (room + bindings + policy bootstrap)

For adapter-owned listeners (Telegram polling / Discord gateway), pass a sink MFA that targets:

- `Jido.Messaging.IngressSink.emit(instance_module, bridge_id, payload, opts)`

### Host Webhook Endpoint (Generic Plug)

```elixir
defmodule MyApp.Webhooks.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  post "/webhooks/:bridge_id" do
    conn =
      Jido.Messaging.WebhookPlug.call(
        conn,
        Jido.Messaging.WebhookPlug.init(
          instance_module: MyApp.Messaging,
          bridge_id_resolver: fn conn -> conn.params["bridge_id"] end
        )
      )

    conn
  end
end
```

### Bridge Config Ingress Modes

```elixir
# Telegram polling ingress (listener worker owned by bridge runtime)
MyApp.Messaging.put_bridge_config(%{
  id: "tg_primary",
  adapter_module: Jido.Chat.Telegram.Adapter,
  opts: %{
    ingress: %{
      mode: "polling",
      token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
      timeout_s: 30,
      poll_interval_ms: 500
    }
  }
})

# Discord gateway ingress (Nostrum ConsumerGroup source by default)
MyApp.Messaging.put_bridge_config(%{
  id: "dc_primary",
  adapter_module: Jido.Chat.Discord.Adapter,
  opts: %{
    ingress: %{
      mode: "gateway",
      poll_interval_ms: 250
    }
  }
})
```

## Demo Topology Bootstrap (YAML)

The demo task supports declarative topology bootstrap from YAML:

```bash
mix jido.messaging.demo --topology config/demo.topology.example.yaml
```

Live Telegram + Discord bridge demo (env-driven topology):

```bash
scripts/demo_bridge_live.sh
```

Supported top-level keys:

- `mode`: `echo | bridge | agent`
- `bridge`: demo runtime bridge opts (`telegram_chat_id`, `discord_channel_id`, adapter modules)
- `bridge_rooms`: one-shot room bootstrap specs (`create_bridge_room/2`)
- `bridge_configs`: control-plane `BridgeConfig` entries
- `rooms`: room bootstrap entries
- `room_bindings`: bridge-scoped room bindings
- `routing_policies`: outbound routing policy bootstrap

Use `config/demo.topology.example.yaml` as the starter template.
For live bridge ingress with Telegram polling + Discord gateway, use
`config/demo.topology.live.yaml` with `.env` values.

## Architecture

```
MyApp.Messaging (Supervisor)
├── Runtime (GenServer) - Manages adapter state
└── (Future) RoomSupervisor, InstanceSupervisor

Message Flow:
1. Host webhook endpoint or adapter listener emits into runtime ingress.
2. `InboundRouter` resolves `BridgeConfig` and adapter module by `bridge_id`.
3. Adapter verifies/parses event; runtime routes through `Jido.Chat.process_event/4`.
4. Message events are ingested (room/participant/message + dedupe/session).
5. Outbound delivery runs through `OutboundRouter`/`OutboundGateway`.
```

## Test Lanes

`jido_messaging` uses lane-based test execution:

- `mix test` or `mix test.core`: core/unit/component tests (default)
- `mix test.integration`: integration-only tests (`@moduletag :integration`)
- `mix test.story`: story/spec contract tests (`@moduletag :story`)
- `mix test.all`: full suite except `:flaky`

## Domain Model

### Message (Canonical)

```elixir
%Jido.Chat.LegacyMessage{
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
%Jido.Chat.Room{
  id: "room_xyz",
  type: :direct | :group | :channel | :thread,
  name: "Support Chat",
  external_bindings: %{telegram: %{"bot_id" => "chat_123"}}
}
```

### Participant

```elixir
%Jido.Chat.Participant{
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
