# Phase 3 Server Pivot: Module Evaluation (`jido_messaging`)

Date: 2026-02-27  
Branch: `feature/phase3-server-pivot`

## Goal
Pivot `jido_messaging` into a runtime/server package that depends on `jido_chat` + `jido_chat_<platform>` adapters, instead of owning channel SDK integrations directly.

## Current Reality (from code)
1. `jido_messaging` currently mixes:
   - runtime/server orchestration
   - domain models and content structs
   - platform channel behaviors and implementations
2. `mix.exs` still includes direct platform deps (`telegex`, `nostrum`, `slack_elixir`, `whatsapp_elixir`).
3. Core channel execution path is centered on `JidoMessaging.Channel` + `JidoMessaging.Channels.*`.
4. `Jido.Chat` already has the canonical adapter contract and normalized event/message surface.

## Recommended Module Boundaries

## Keep in `jido_messaging` (server/runtime)
1. Runtime composition and process topology:
   - `JidoMessaging.Supervisor`
   - `JidoMessaging.Runtime`
   - `JidoMessaging.Instance*`
   - `JidoMessaging.Room*`
   - `JidoMessaging.Agent*`
   - `JidoMessaging.SessionManager*`
   - `JidoMessaging.OutboundGateway*`
   - `JidoMessaging.DeadLetter*`
   - `JidoMessaging.Deduper`
2. Runtime policy/ops:
   - `JidoMessaging.Ingest`
   - `JidoMessaging.Deliver`
   - `JidoMessaging.Security*`
   - `JidoMessaging.Gating`
   - `JidoMessaging.Moderation*`
   - `JidoMessaging.AuditLogger`
   - `JidoMessaging.Signal*`
   - `JidoMessaging.Onboarding*`
   - `JidoMessaging.Directory`
3. Persistence contract:
   - `JidoMessaging.Adapter`
   - `JidoMessaging.Adapters.ETS`

## Remove from `jido_messaging` ownership (delegate to `jido_chat*`)
1. Channel behavior and platform implementations:
   - `JidoMessaging.Channel`
   - `JidoMessaging.Channels.Telegram*`
   - `JidoMessaging.Channels.Discord*`
   - `JidoMessaging.Channels.Slack*`
   - `JidoMessaging.Channels.WhatsApp*`
2. Channel-specific parser helpers that belong in adapters:
   - `JidoMessaging.Adapters.Mentions`
   - `JidoMessaging.Adapters.Threading`
   - channel handlers that transform webhook payloads

## Compatibility wrappers to keep for one migration phase
1. Domain structs used heavily in runtime APIs:
   - `JidoMessaging.Message` -> wrap/alias to `Jido.Chat.LegacyMessage`
   - `JidoMessaging.Room` -> wrap/alias to `Jido.Chat.Room`
   - `JidoMessaging.Participant` -> wrap/alias to `Jido.Chat.Participant`
   - `JidoMessaging.MessagingTarget` -> wrap/alias to `Jido.Chat.MessagingTarget`
2. Content wrappers:
   - `JidoMessaging.Content.*` -> wrappers to `Jido.Chat.Content.*`
3. Capabilities wrapper:
   - `JidoMessaging.Capabilities` -> thin wrapper around `Jido.Chat.Capabilities` + runtime-specific checks only

## New Server-Focused Modules to Add
1. `JidoMessaging.AdapterBridge`
   - single boundary from runtime -> `Jido.Chat.Adapter`
   - transforms runtime context into adapter calls (`send/edit/delete/typing/fetch`)
2. `JidoMessaging.InboundRouter`
   - normalize inbound events (`Jido.Chat.EventEnvelope`) to runtime ingest actions
3. `JidoMessaging.OutboundRouter`
   - convert runtime outbound intents into `Jido.Chat.PostPayload` / adapter operations
4. `JidoMessaging.ChannelRegistry` (optional rename from `PluginRegistry`)
   - store adapter modules and capability matrices, not platform SDK modules

## Refactor Sequence (low-risk)
1. **Dependency pivot first**
   - Add `:jido_chat` dep.
   - Remove direct platform deps from `jido_messaging`.
   - Keep platform runtime wiring by requiring adapter modules from `jido_chat_<platform>` packages.
2. **Bridge layer**
   - Introduce `AdapterBridge`.
   - Update `OutboundGateway.Partition` to call bridge (`Jido.Chat.Adapter.*`) instead of `JidoMessaging.Channel.*`.
3. **Inbound pivot**
   - Update webhook/gateway handlers to produce `Jido.Chat.EventEnvelope`.
   - Route through `Jido.Chat.process_event/4` and then runtime ingest hooks.
4. **Compatibility shims**
   - Keep `JidoMessaging.Channel` as deprecated compatibility wrapper delegating to `AdapterBridge`.
   - Keep `JidoMessaging.Message/Room/Participant/Content` wrappers for one phase.
5. **Cleanup**
   - Remove `JidoMessaging.Channels.*` modules and direct platform tests.
   - Move platform integration tests to `jido_chat_<platform>` packages.

## Suggested Final Server Module Set
1. Public API:
   - `JidoMessaging`
   - `JidoMessaging.Runtime`
   - `JidoMessaging.Supervisor`
2. Runtime workers:
   - `Instance*`, `Room*`, `Agent*`, `SessionManager*`, `OutboundGateway*`, `DeadLetter*`, `Deduper`
3. Runtime pipelines:
   - `Ingest`, `Deliver`, `InboundRouter`, `OutboundRouter`, `AdapterBridge`
4. Runtime policy:
   - `Security*`, `Gating`, `Moderation*`, `MediaPolicy`
5. Runtime observability:
   - `Signal*`, `AuditLogger`, `PubSub`
6. Persistence:
   - `Adapter`, `Adapters.ETS`, directory/binding modules
7. Transitional compatibility:
   - `Message`, `Room`, `Participant`, `Content.*`, `Capabilities`, `MessagingTarget` (wrappers only)

## Immediate Risks to Manage
1. `JidoMessaging` facade is large (623 lines) and mixes runtime + domain CRUD.
2. Outbound pipeline currently assumes `JidoMessaging.Channel` failure taxonomy.
3. Plugin registry currently assumes channel modules, not adapter modules.
4. Existing tests are heavily channel-module-centric; they need split by ownership (`jido_messaging` runtime vs `jido_chat_<platform>` adapters).

## First Concrete Batch to Implement Next
1. Add `:jido_chat` dependency and compile-time adapter bridge.
2. Introduce `JidoMessaging.AdapterBridge` with parity wrappers:
   - `transform_incoming`
   - `send_message`
   - `edit_message`
   - `send_media`/`edit_media` (fallback policy through `PostPayload`)
   - failure normalization to existing outbound categories
3. Convert `OutboundGateway.Partition` to call bridge.
4. Keep old channel modules temporarily but route through bridge to avoid big-bang break.
