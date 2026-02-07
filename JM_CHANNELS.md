# JidoMessaging Channel Implementation Plan

## Current State

### Architecture

Every channel follows a two-module pattern:

1. **Channel module** (`channels/X.ex`) — implements `JidoMessaging.Channel` behaviour:
   - `channel_type/0` — atom identifier
   - `capabilities/0` — supported content types
   - `transform_incoming/1` — platform payload → normalized `incoming_message` map
   - `send_message/3` — send text to external platform
   - `edit_message/4` (optional) — update existing message (for streaming)

2. **Handler module** (`channels/X/handler.ex`) — bridges the platform's event system into the ingest/deliver pipeline:
   - Receives platform events (polling, websocket, webhook, or IO)
   - Calls `Channel.transform_incoming/1`
   - Calls `Ingest.ingest_incoming/4` (dedup → resolve room/participant → persist → signal)
   - Runs `on_message` callback
   - Calls `Deliver.deliver_outgoing/5` for replies

### Implemented Channels

| Channel | Dep | Handler Shape | Status |
|---------|-----|---------------|--------|
| **Telegram** | `telegex ~> 1.8` | `use Telegex.Polling.GenHandler` — long-poll process | ✅ Done |
| **Discord** | `nostrum ~> 0.10` | `use Nostrum.Consumer` — gateway websocket consumer | ✅ Done |
| **Slack** | `slack_elixir ~> 1.2` | `use Slack.Bot` — Socket Mode websocket consumer | ✅ Done |
| **WhatsApp** | `whatsapp_elixir ~> 0.1.8` | Webhook controller — `process_webhook/2` called from Phoenix | ✅ Done |

### Pipeline Flow

```
Platform Event
  → Handler (platform-specific event listener)
    → Channel.transform_incoming/1 (normalize)
      → Ingest.ingest_incoming/4 (dedup, resolve room/participant, persist, signal)
        → on_message callback (application logic)
          → Deliver.deliver_outgoing/5 (persist reply, Channel.send_message/3, signal)
```

---

## Phase 1: Twilio SMS

**Priority:** High — fills the SMS/phone gap, large user base, reliable Hex package.

### Dependency

```elixir
{:ex_twilio, "~> 0.10"}
```

- Well-maintained, widely used
- Provides `ExTwilio.Message.create/2` for sending
- Provides `ExTwilio.RequestValidator.valid?/3` for webhook signature validation
- Supports SMS, MMS, and WhatsApp via Twilio (initially SMS only)

### Channel Module: `channels/twilio_sms.ex`

```
channel_type:  :twilio_sms
capabilities:  [:text]  (MMS/media deferred)
```

**Identity mapping:**
- `external_room_id` → `From` (sender's phone number, one conversation per number)
- `external_user_id` → `From`
- `external_message_id` → `MessageSid`
- `instance_id` → `To` (your Twilio number) or configured name

**`transform_incoming/1`** — Parses Twilio webhook params (URL-encoded form data):
```elixir
%{
  "From" => "+15551234567",
  "To" => "+15559876543",
  "Body" => "Hello!",
  "MessageSid" => "SM...",
  "NumMedia" => "0"
}
```

**`send_message/3`** — Calls `ExTwilio.Message.create(to: phone, from: configured_number, body: text)`.

### Handler Module: `channels/twilio_sms/handler.ex`

**Shape:** Webhook controller (same pattern as WhatsApp.Handler).

**Public API:**
- `validate_signature(conn_or_url, params, auth_token)` — wraps `ExTwilio.RequestValidator.valid?/3`
- `process_webhook(params, opts)` — main entry point called from Phoenix controller

**Flow:**
1. (Recommended) Validate `X-Twilio-Signature` header
2. `TwilioSMS.transform_incoming(params)`
3. `Ingest.ingest_incoming(messaging, TwilioSMS, instance_id, incoming)`
4. Run `on_message` callback → `Deliver.deliver_outgoing/5`
5. Return immediately (200 + `<Response/>` TwiML or empty body)

**Handler opts map:**
```elixir
%{
  messaging: MyApp.Messaging,
  on_message: &MyApp.MessageHandler.handle/2,
  instance_id: "twilio_main",     # optional, defaults to "twilio_sms"
  from_number: "+15559876543"     # Twilio number for outbound, or use config
}
```

**Phoenix integration example:**
```elixir
# router.ex
post "/webhooks/twilio/sms", TwilioSMSController, :webhook

# controller
def webhook(conn, params) do
  Handler.process_webhook(params, @handler_opts)
  send_resp(conn, 200, "<Response/>")
end
```

### Supervision

No dedicated process required. Inbound = HTTP webhook, outbound = HTTP API call.

### Instance.channel_type update

Add `:twilio_sms` to the `Zoi.enum` in `Instance` schema.

### Special Considerations

- **Signature validation is URL-sensitive.** Behind proxies, `Plug.Conn.request_url/1` must match the URL Twilio signed against. Document that `Endpoint` config must have correct `url: [scheme: "https", host: "..."]`.
- **STOP/HELP compliance.** Twilio handles opt-out at the carrier level, but document that bots should not auto-reply to "STOP" messages.
- **MMS/media (deferred).** Twilio sends `NumMedia` + `MediaUrl0..N`. Add `:image` capability and media download support in a follow-up.
- **Delivery status callbacks (deferred).** Twilio can POST status updates (`MessageStatus`). Could update message status from `:sent` to `:delivered`/`:failed` via a second webhook endpoint.

### Test Plan

- Unit tests for `TwilioSMS.transform_incoming/1` with various param shapes
- Unit tests for `TwilioSMS.send_message/3` (mock `ExTwilio.Message.create/2`)
- Unit tests for `Handler.process_webhook/2` with mock messaging module
- Signature validation tests

### Effort: M (1–2 days)

---

## Phase 2: TUI (Terminal User Interface)

**Priority:** High — critical for developer experience, testing, and CLI agent tools.

### Dependency

```elixir
{:term_ui, github: "pcharbon70/term_ui", branch: "develop", optional: true}
```

- Full-featured terminal UI framework inspired by BubbleTea (Go) and Ratatui (Rust)
- Elm Architecture (init/update/view) — predictable state, testable, composable
- Rich widget library: TextInput, Table, Viewport, Gauge, Sparkline, Dialog, etc.
- Double-buffered differential rendering at 60 FPS
- OTP-native: supervision trees, fault tolerance, hot code reload
- IEx compatible — run TUI apps directly in IEx for development
- Requires OTP 28+

### Channel Module: `channels/tui.ex`

```
channel_type:  :tui
capabilities:  [:text, :streaming]
```

**Identity mapping:**
- `external_room_id` → `"tui"` or `"tui:<session_id>"` (configurable)
- `external_user_id` → `System.get_env("USER")` or `"local"` (configurable)
- `external_message_id` → `System.unique_integer([:positive, :monotonic])`

**`transform_incoming/1`** — Accepts either:
- A raw string (user typed a line)
- A map `%{text: ..., external_user_id: ..., external_room_id: ...}`

Wraps into the standard `incoming_message` shape.

**`send_message/3`** — Sends a message to the TUI process for rendering:
- Sends `{:jido_tui_message, %{text: text, role: :assistant, ...}}` to the TUI runtime
- The TUI's `update/2` handler appends it to the transcript and triggers a re-render
- Returns `{:ok, %{message_id: unique_integer}}`

**`edit_message/4`** — Supports streaming updates:
- Sends `{:jido_tui_edit, %{message_id: id, text: updated_text}}` to the TUI runtime
- The TUI's `update/2` handler patches the last assistant message in the transcript
- Gives a ChatGPT-like streaming feel in the terminal

### Handler Module: `channels/tui/handler.ex`

**Shape:** TermUI Elm Architecture component (`use TermUI.Elm`).

This is NOT an IO.gets loop. It's a full-screen terminal app with a scrolling message transcript and a TextInput widget at the bottom — like a real chat client.

**Architecture:**

```
┌─────────────────────────────────────────┐
│  JidoMessaging Chat                     │
│─────────────────────────────────────────│
│  [user] Hello, what can you do?         │
│  [assistant] I can help with...         │
│  [user] Tell me more                    │
│  [assistant] Sure! Here are some...     │
│                                         │
│                                         │
│─────────────────────────────────────────│
│  > Type a message...                    │
└─────────────────────────────────────────┘
```

**TermUI Elm Architecture callbacks:**

```elixir
defmodule MyApp.ChatTUI do
  use TermUI.Elm

  alias TermUI.Widgets.TextInput
  alias TermUI.Event

  # init/1 — set up state with empty transcript + TextInput widget
  def init(opts) do
    messaging = Keyword.fetch!(opts, :messaging)
    on_message = Keyword.get(opts, :on_message)
    instance_id = Keyword.get(opts, :instance_id, "tui")

    props = TextInput.new(placeholder: "Type a message...", width: 80, enter_submits: true)
    {:ok, input_state} = TextInput.init(props)

    %{
      messaging: messaging,
      on_message: on_message,
      instance_id: instance_id,
      messages: [],                           # [{role, text}]
      input: TextInput.set_focused(input_state, true),
      scroll_offset: 0
    }
  end

  # event_to_msg/2 — map key events to app messages
  def event_to_msg(%Event.Key{key: :enter}, state) do
    text = TextInput.get_value(state.input)
    if text != "", do: {:msg, {:submit, text}}, else: :ignore
  end
  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :quit}
  def event_to_msg(event, _state), do: {:msg, {:input_event, event}}

  # update/2 — handle messages, run ingest/deliver pipeline
  def update({:submit, text}, state) do
    # 1. Add user message to transcript
    # 2. Clear input
    # 3. Use Command.timer(0, {:process, text}) to async ingest
    ...
  end

  def update({:process, text}, state) do
    # Run Ingest.ingest_incoming/4 → on_message → Deliver
    # Deliver calls TUI.send_message/3 which sends {:jido_tui_message, ...}
    ...
  end

  def update({:jido_tui_message, payload}, state) do
    # Append assistant message to transcript, auto-scroll
    ...
  end

  def update({:jido_tui_edit, payload}, state) do
    # Patch last assistant message (streaming)
    ...
  end

  # view/1 — render transcript + input using TermUI primitives
  def view(state) do
    stack(:vertical, [
      # Header
      text("JidoMessaging Chat", Style.new(fg: :cyan, bold: true)),
      # Scrollable transcript
      render_transcript(state.messages),
      # Divider
      text(String.duplicate("─", 80), Style.new(fg: :bright_black)),
      # Input
      TextInput.render(state.input, %{width: 80, height: 1})
    ])
  end
end
```

**`__using__` macro for convenience:**
```elixir
use JidoMessaging.Channels.TUI.Handler,
  messaging: MyApp.Messaging,
  on_message: &MyApp.MessageHandler.handle/2,
  instance_id: "tui",
  room_id: "tui",
  user_id: "local"
```

The macro generates a TermUI.Elm module with all the callbacks wired up, so users don't have to write the boilerplate.

**Running:**
```elixir
# In iex (TermUI is IEx-compatible)
TermUI.run(MyApp.ChatTUI, messaging: MyApp.Messaging, on_message: &handler/2)

# As a mix task
mix jido.chat --messaging MyApp.Messaging

# In supervision tree (for CLI apps)
{MyApp.ChatTUI, messaging: MyApp.Messaging, on_message: &handler/2}
```

### Supervision

- In dev/CLI apps: add directly to supervision tree, or run ad-hoc via `TermUI.run/2`
- In mix tasks: `TermUI.run/2` blocks until `:quit` command
- Should NOT be added to a web app's supervision tree
- TermUI handles its own terminal setup/teardown (raw mode, alternate screen, cursor)

### Instance.channel_type update

Add `:tui` to the `Zoi.enum` in `Instance` schema.

### Special Considerations

- **TermUI manages the terminal.** No manual IO.gets/IO.puts — TermUI owns raw mode, rendering, and input parsing. The channel's `send_message/3` communicates via process messages, not stdout.
- **Guard TermUI dependency.** Use `Code.ensure_loaded?(TermUI.Elm)` since it's optional.
- **OTP 28+ required.** TermUI uses native raw terminal mode from OTP 28. Document this requirement.
- **Streaming support.** TermUI's 60 FPS rendering + `edit_message/4` gives smooth token-by-token streaming. Rate-limit via the existing `Streaming` GenServer or TermUI's built-in `Command.timer` debouncing.
- **No PubSub needed.** The TUI process receives messages directly from `Deliver` via `send_message/3`. The Elm update loop handles state changes.
- **Transcript scrolling.** Use TermUI's Viewport widget or manual scroll offset tracking for long conversations.
- **Slash commands.** Detect `/history`, `/clear`, `/quit` prefixes in the submit handler for power-user features.
- **IEx compatibility.** TermUI works in IEx, making it great for interactive development — start a chat session, test agent responses, iterate.

### Test Plan

- Unit tests for `TUI.transform_incoming/1` with string and map inputs
- Unit tests for `TUI.send_message/3` (verify process message sent)
- Unit tests for the Elm Architecture callbacks: `init/1`, `update/2`, `view/1` (TermUI's testing framework supports this)
- Integration test with mock messaging module

### Effort: M (1–2 days)

---

## Phase 3: LiveView (Embeddable Chat Component)

**Priority:** Medium — enables web-based chat UIs, admin panels, support widgets.

### Dependencies

```elixir
{:phoenix, "~> 1.7", optional: true}
{:phoenix_live_view, "~> 1.0", optional: true}
{:phoenix_html, ">= 4.0.0", optional: true}
```

All optional. `phoenix_pubsub` is already a runtime dep.

### Channel Module: `channels/live_view.ex`

```
channel_type:  :live_view
capabilities:  [:text, :streaming]
```

**Identity mapping:**
- `external_room_id` → a **room key** string (e.g., `"support:123"`, `"user:42"`, `"dev"`)
- `external_user_id` → authenticated user ID from the host app's session/assigns
- `external_message_id` → `System.unique_integer([:positive])`

**`send_message/3`** — Does NOT call an external API. Instead, broadcasts to PubSub:
```elixir
Phoenix.PubSub.broadcast(
  pubsub_server,
  "jido_messaging:live_view:#{instance_id}:#{room_key}",
  {:jido_message, %{text: text, message_id: id, role: :assistant, ...}}
)
```
Returns `{:ok, %{message_id: id}}`.

**`edit_message/4`** — Broadcasts `{:jido_message_edit, %{message_id: id, text: updated_text}}` for streaming token updates.

**PubSub server resolution:**
1. `opts[:pubsub]` passed at call time
2. `Application.get_env(:jido_messaging, :pubsub_server)`
3. Host app must have PubSub running (standard for any Phoenix app)

### Handler Module: `channels/live_view/handler.ex`

**Shape:** Helper functions (not a GenServer). The LiveView process IS the handler.

**Public API:**
```elixir
# Subscribe the current LiveView process to room messages
Handler.subscribe(pubsub, instance_id, room_key)

# Build the PubSub topic string
Handler.topic(instance_id, room_key)

# Process a user message (called from handle_event)
Handler.process_user_message(messaging, instance_id, room_key, user_key, text, on_message)
```

**`process_user_message/6` flow:**
1. Build incoming map:
   ```elixir
   %{
     external_room_id: room_key,
     external_user_id: user_key,
     text: text,
     external_message_id: System.unique_integer([:positive]),
     chat_type: :direct
   }
   ```
2. `Ingest.ingest_incoming(messaging, LiveView, instance_id, incoming)`
3. Run `on_message` callback
4. `Deliver.deliver_outgoing/5` → calls `LiveView.send_message/3` → broadcasts to PubSub
5. The LiveView's `handle_info({:jido_message, payload}, socket)` receives the broadcast and updates assigns

### Component: `live/chat_component.ex`

A `Phoenix.LiveComponent` that can be dropped into any LiveView:

```heex
<.live_component
  module={JidoMessaging.Live.ChatComponent}
  id="chat"
  messaging={MyApp.Messaging}
  instance_id="web"
  room_key="support:123"
  user_key={@current_user.id}
  on_message={&MyApp.AgentHandler.handle/2}
/>
```

**Assigns:**
- `messaging` — the JidoMessaging instance module (required)
- `instance_id` — string instance identifier (required)
- `room_key` — string room identifier (required)
- `user_key` — authenticated user ID string (required)
- `on_message` — callback function (optional)
- `class` — CSS class for outer container (optional)

**Component responsibilities:**
- `mount` → subscribe to PubSub topic, load message history from adapter
- Render transcript (list of messages with role-based styling)
- Render text input with `phx-submit="send"`
- `handle_event("send", ...)` → `Handler.process_user_message/6`
- `handle_info({:jido_message, ...})` → append to transcript stream
- `handle_info({:jido_message_edit, ...})` → patch existing message (streaming)

### Supervision

No new processes. LiveView processes are managed by Phoenix. PubSub is the transport.

### Instance.channel_type update

Add `:live_view` to the `Zoi.enum` in `Instance` schema.

### Special Considerations

- **Keep Phoenix deps optional.** Guard all LiveView/Phoenix modules with `Code.ensure_loaded?/1` checks, or consider a separate `jido_messaging_live` package if isolation is critical.
- **Authentication.** The component must NOT trust `user_key` blindly. The host app is responsible for passing a verified user ID from session/assigns. Document this clearly.
- **Room key strategy.** Document recommended patterns: `"user:<id>"` for 1:1 support, `"topic:<slug>"` for topic rooms, etc. The ingest pipeline creates/resolves rooms by external binding automatically.
- **CSS/styling.** Ship with minimal default styles. Provide CSS class hooks for customization. Don't force Tailwind or any framework.
- **Streaming support.** `edit_message/4` broadcasts patch events. The component updates the last assistant message in-place for a ChatGPT-like streaming feel. Rate-limit via the existing `Streaming` GenServer.

### Test Plan

- Unit tests for `LiveView` channel (transform_incoming, send_message broadcasts)
- Unit tests for `Handler` helper functions
- LiveView integration tests using `Phoenix.LiveViewTest` (connect, send message, receive broadcast)

### Effort: L (1–2 days)

---

## Instance Schema Update

The `Instance` module's `channel_type` enum needs to be extended:

```elixir
# Current
channel_type: Zoi.enum([:telegram, :discord, :slack, :whatsapp, :internal])

# Updated
channel_type: Zoi.enum([:telegram, :discord, :slack, :whatsapp, :twilio_sms, :tui, :live_view, :internal])
```

---

## File Summary

### Phase 1: Twilio SMS
```
lib/jido_messaging/channels/twilio_sms.ex          # Channel behaviour impl
lib/jido_messaging/channels/twilio_sms/handler.ex   # Webhook handler
test/jido_messaging/channels/twilio_sms_test.exs    # Tests
```

### Phase 2: TUI
```
lib/jido_messaging/channels/tui.ex                  # Channel behaviour impl
lib/jido_messaging/channels/tui/handler.ex           # Interactive GenServer
test/jido_messaging/channels/tui_test.exs            # Tests
```

### Phase 3: LiveView
```
lib/jido_messaging/channels/live_view.ex             # Channel behaviour impl
lib/jido_messaging/channels/live_view/handler.ex     # Helper functions
lib/jido_messaging/live/chat_component.ex            # Phoenix.LiveComponent
test/jido_messaging/channels/live_view_test.exs      # Tests
```

### Shared
```
lib/jido_messaging/instance.ex                       # Add new channel_type atoms
mix.exs                                              # Add ex_twilio, owl, phoenix deps
```

---

## Dependency Summary

| Dep | Version | Optional? | Phase |
|-----|---------|-----------|-------|
| `ex_twilio` | `~> 0.10` | No | 1 |
| `term_ui` | `github: pcharbon70/term_ui, branch: develop` | Yes | 2 |
| `phoenix` | `~> 1.7` | Yes | 3 |
| `phoenix_live_view` | `~> 1.0` | Yes | 3 |
| `phoenix_html` | `>= 4.0.0` | Yes | 3 |

---

## Deferred / Future Work

- **Twilio MMS:** Parse `NumMedia` + `MediaUrl0..N`, download media, add `:image` capability
- **Twilio delivery status:** Second webhook endpoint for `MessageStatus` callbacks, update message status
- **TUI split pane:** Use TermUI's SplitPane widget for sidebar (rooms/agents) + main chat area
- **TUI agent dashboard:** Combine chat with Gauge/Sparkline widgets for agent health monitoring
- **TUI multi-room tabs:** Use TermUI's Tabs widget to switch between rooms
- **LiveView presence:** Typing indicators, online status via `Phoenix.Presence`
- **LiveView file upload:** Support `:image`/`:file` capabilities via LiveView uploads
- **LiveView multi-room:** Tab/sidebar UI for managing multiple rooms in one component
