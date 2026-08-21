# Jido Messaging

[![Hex.pm](https://img.shields.io/hexpm/v/jido_messaging.svg)](https://hex.pm/packages/jido_messaging)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_messaging/)
[![CI](https://github.com/agentjido/jido_messaging/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_messaging/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_messaging.svg)](https://github.com/agentjido/jido_messaging/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

Messaging and notification system for the Jido ecosystem. Provides a unified interface for building conversational AI agents across multiple channels (Telegram, Discord, Slack, etc.).

## Release Status

This package is being prepared for the Jido 1.x messaging release line.
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
    {:jido_messaging, "~> 1.1"}
  ]
end
```

## Quick Start

### 1. Define Your Messaging Module

```elixir
defmodule MyApp.Messaging do
  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.ETS
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
  content: [%{type: :text, text: "Hello!"}]
})

# List messages
{:ok, messages} = MyApp.Messaging.list_messages(room.id)
```

### Eventful Commands

Use low-level persistence functions such as `save_message/1` for imports,
migrations, and tests that should not notify realtime consumers. Use eventful
commands when a write should emit canonical `jido.messaging.*` signals:

```elixir
{:ok, result} =
  MyApp.Messaging.post_message(%{
    room_id: room.id,
    sender_id: "user_123",
    role: :user,
    content: [%{type: :text, text: "Hello!"}]
  })

message = result.record
[%Jido.Signal{type: "jido.messaging.room.message_added"}] = result.signals
```

Subscribe to the instance Signal Bus for application UI or bridge notifications:

```elixir
{:ok, subscription_id} = MyApp.Messaging.subscribe_signals("jido.messaging.room.**")
:ok = MyApp.Messaging.unsubscribe_signals(subscription_id)
```

### Durable SQLite Persistence

Use the SQLite adapter when the host app needs durable local messaging state:

```elixir
defmodule MyApp.Messaging do
  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.SQLite,
    persistence_opts: [path: "data/my_app_messaging.sqlite3"]
end
```

The SQLite adapter stores canonical rooms, participants, messages, threads,
bridge bindings, routing policies, bridge configs, and ingress subscriptions.
`room_timeline/2` returns top-level messages, grouped thread replies, and reply
counts from the persisted message records.

Each `Jido.Messaging` runtime uses its module name as a SQLite instance
namespace. Different runtimes can therefore share one database path without
reading or replacing each other's records. Set `persistence_opts: [instance_id:
"stable-name"]` when a namespace must remain stable across a module rename.
Direct calls to `Jido.Messaging.Persistence.SQLite.init/1` use the explicit
default namespace `"default"` unless `:instance_id` is supplied.

Inbound participant identity is scoped by adapter and bridge ID. This prevents
equal tenant-local provider IDs from merging participants across workspaces or
server installations. Use `bind_participant_external_id/4` to link another
provider identity to an existing canonical participant. Legacy unscoped calls
use the explicit `"default"` bridge scope. SQLite assigns an unclaimed legacy
participant record to the first matching scoped identity; applications can use
the binding API before traffic starts when a different migration is required.

### Presence Signals

`Jido.Messaging.Presence` bridges transport-specific presence state, such as
Phoenix Presence, into canonical messaging participant signals:

```elixir
defmodule MyApp.Presence do
  use Jido.Messaging.Presence,
    messaging: MyApp.Messaging,
    presence: MyAppWeb.Presence,
    topic: "my_app:presence",
    source: "my_app.presence"
end
```

Call `touch/3` when a participant is seen online and `mark_left/2` when a
session disconnects. The helper emits `jido.messaging.room.participant_joined`,
`jido.messaging.room.participant_left`, and
`jido.messaging.participant.presence_changed` signals.

## Adapter Integration (Telegram + Discord)

`jido_messaging` no longer ships in-package Telegram/Discord handlers.  
Use adapter packages directly:

- `jido_chat_telegram` (`Jido.Chat.Telegram.Adapter`)
- `jido_chat_discord` (`Jido.Chat.Discord.Adapter`)

### Dependencies

```elixir
def deps do
  [
    {:jido_chat, "~> 1.0"},
    {:jido_chat_telegram, "~> 1.1"},
    {:jido_chat_discord, "~> 1.0"},
    {:jido_messaging, "~> 1.1"}
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
%Jido.Messaging.Message{
  id: "msg_abc123",
  room_id: "room_xyz",
  sender_id: "user_123",
  thread_id: "thread_123",
  external_thread_id: "platform_thread_123",
  delivery_external_room_id: "platform_delivery_target_123",
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
