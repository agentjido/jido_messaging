# Jido Messaging Hard-Break Rewrite Plan

Date: 2026-02-27  
Branch: `feature/phase3-server-pivot`  
Status: Proposed

## Objective
Rewrite `jido_messaging` into a runtime/server package with canonical namespace `Jido.Messaging.*`, using `Jido.Chat.*` as the canonical domain and adapter boundary.

This is a hard break:
1. No backwards compatibility shims.
2. No legacy `JidoMessaging.*` compatibility modules.
3. No in-package platform channel SDK implementations.

## Locked Decisions
1. Canonical namespace is `Jido.Messaging.*`.
2. Canonical domain structs come from `Jido.Chat.*`:
   - `Jido.Chat.LegacyMessage` (runtime message persistence shape)
   - `Jido.Chat.Room`
   - `Jido.Chat.Participant`
   - `Jido.Chat.MessagingTarget`
   - `Jido.Chat.Content.*`
   - `Jido.Chat.Capabilities`
3. Adapter boundary is `Jido.Chat.Adapter` only.
4. Platform packages remain separate:
   - `jido_chat_telegram`
   - `jido_chat_discord`
   - future `jido_chat_slack`, `jido_chat_whatsapp`, etc.
5. Runtime remains process-first (supervision tree), with configurable bridge routing.

## Architecture

## Control Plane (runtime-editable)
1. `Jido.Messaging.BridgeConfig` (Zoi struct):
   - `id`, `adapter`, `credentials`, `opts`, `enabled`, `capabilities`, `revision`.
2. `Jido.Messaging.RoomBinding` (Zoi struct):
   - `room_id`, `bridge_id`, `external_room_id`, `external_thread_id`, `mode`, `priority`, `revision`.
3. `Jido.Messaging.RoutingPolicy` (Zoi struct):
   - fallback order, delivery mode, failover policy, dedupe policy.
4. `Jido.Messaging.ConfigStore`:
   - single writer process + ETS snapshot for read path.
   - optimistic concurrency via `revision`.

## Data Plane
1. `Jido.Messaging.AdapterBridge`:
   - wraps all `Jido.Chat.Adapter` calls.
   - performs request/response normalization for runtime.
2. `Jido.Messaging.InboundRouter`:
   - takes raw payloads and bridge id.
   - delegates parse to adapter (`verify_webhook/parse_event`).
   - routes normalized envelopes to runtime ingest.
3. `Jido.Messaging.OutboundRouter`:
   - resolves room binding and bridge policy.
   - calls AdapterBridge for `send/edit/delete/typing/reaction/fetch`.

## Target Process Tree
1. Root: `Jido.Messaging.Supervisor`
2. Children:
   - registries
   - signal bus
   - room supervisor
   - agent supervisor
   - onboarding supervisor
   - session manager supervisor
   - dead letter + replay supervisor
   - outbound gateway supervisor
   - bridge supervisor
   - deduper
   - runtime
3. Per-bridge subtree:
   - `Jido.Messaging.BridgeServer`
   - adapter listener children (from adapter capability, if any)
   - reconnect worker

## Module Rewrite Matrix

## Delete (hard break)
1. `JidoMessaging.Channel`
2. `JidoMessaging.Channels.*` (telegram/discord/slack/whatsapp + handlers + mentions adapters)
3. `JidoMessaging.Adapters.Mentions`
4. `JidoMessaging.Adapters.Threading`

## Rename to `Jido.Messaging.*`
1. `JidoMessaging` -> `Jido.Messaging`
2. `JidoMessaging.Supervisor` -> `Jido.Messaging.Supervisor`
3. `JidoMessaging.Runtime` -> `Jido.Messaging.Runtime`
4. `JidoMessaging.Ingest` -> `Jido.Messaging.Ingest`
5. `JidoMessaging.Deliver` -> `Jido.Messaging.Deliver`
6. `JidoMessaging.OutboundGateway*` -> `Jido.Messaging.OutboundGateway*`
7. `JidoMessaging.SessionManager*` -> `Jido.Messaging.SessionManager*`
8. `JidoMessaging.DeadLetter*` -> `Jido.Messaging.DeadLetter*`
9. `JidoMessaging.Instance*` -> `Jido.Messaging.Instance*`
10. `JidoMessaging.Room*` -> `Jido.Messaging.Room*`
11. `JidoMessaging.Agent*` -> `Jido.Messaging.Agent*`
12. `JidoMessaging.Security*` -> `Jido.Messaging.Security*`
13. `JidoMessaging.Moderation*` -> `Jido.Messaging.Moderation*`
14. `JidoMessaging.Gating` -> `Jido.Messaging.Gating`
15. `JidoMessaging.Signal*` -> `Jido.Messaging.Signal*`
16. `JidoMessaging.PluginRegistry` -> `Jido.Messaging.BridgeRegistry`

## Replace struct references with `Jido.Chat.*`
1. `JidoMessaging.Message` -> `Jido.Chat.LegacyMessage`
2. `JidoMessaging.Room` -> `Jido.Chat.Room`
3. `JidoMessaging.Participant` -> `Jido.Chat.Participant`
4. `JidoMessaging.MessagingTarget` -> `Jido.Chat.MessagingTarget`
5. `JidoMessaging.Content.*` -> `Jido.Chat.Content.*`
6. `JidoMessaging.Capabilities` -> `Jido.Chat.Capabilities`

## Keep runtime-local structs
1. `Instance`
2. `Runtime`
3. `MsgContext`
4. `RoomBinding` (runtime binding model)
5. sender/dead-letter/session internal state structs

## Dependency Plan

## Remove from `jido_messaging` deps
1. `telegex`
2. `finch` (only if solely for channel layer)
3. `multipart` (only if solely for channel layer)
4. `nostrum`
5. `slack_elixir`
6. `whatsapp_elixir`

## Add/keep
1. Add `{:jido_chat, path: "../jido_chat"}`
2. Keep runtime deps (`jido`, `jido_signal`, `jido_ai`, telemetry, pubsub, zoi, jason)
3. Adapter package deps are application-level or optional plugin deps, not core runtime deps.

## Delivery Phases

## Phase 1: Namespace + Dependency Hard Break
1. Rename all modules from `JidoMessaging.*` to `Jido.Messaging.*`.
2. Remove direct platform deps from `mix.exs`.
3. Add `jido_chat` dependency.
4. Delete `JidoMessaging.Channel` and `JidoMessaging.Channels.*`.

Exit criteria:
1. Project compiles with new namespace.
2. No references to `JidoMessaging.Channels.*` or `JidoMessaging.Channel`.

## Phase 2: AdapterBridge + Registry
1. Implement `Jido.Messaging.AdapterBridge` over `Jido.Chat.Adapter`.
2. Replace old plugin/channel registry with `BridgeRegistry` keyed by bridge id + adapter module.
3. Add runtime-editable config store (`BridgeConfig`, `RoomBinding`, `RoutingPolicy`).

Exit criteria:
1. Outbound path can resolve bridge + send through `Jido.Chat.Adapter`.
2. Capabilities come from `Jido.Chat.Adapter.capabilities/1`.

## Phase 3: Inbound/Outbound Pipeline Rewrite
1. Rewrite ingest entrypoints to consume adapter-generated event envelopes.
2. Route through `Jido.Chat.process_event/4` as canonical typed event path.
3. Rewrite `OutboundGateway.Partition` operations to use AdapterBridge.

Exit criteria:
1. No runtime references to old channel callbacks.
2. Inbound/outbound tests pass with adapter mocks.

## Phase 4: Process Tree Refinement
1. Replace instance channel module resolution with bridge runtime resolution.
2. Bridge-specific listener child specs start under bridge subtree.
3. Keep room/agent/session/dead-letter/outbound supervisors unchanged where possible.

Exit criteria:
1. Bridge lifecycle is supervised and restartable.
2. Room dynamics independent from adapter SDK process details.

## Phase 5: Test Rewrite + Quality Gates
1. Rename tests to `Jido.Messaging.*`.
2. Replace channel implementation tests with adapter-bridge integration tests.
3. Add conformance tests:
   - capability mapping correctness
   - unsupported behavior explicitness
   - routing fallback determinism
4. Run:
   - `mix test`
   - `mix quality`

Exit criteria:
1. All tests green under new namespace and runtime model.
2. No legacy module references.

## Acceptance Criteria
1. Namespace is fully `Jido.Messaging.*`.
2. `Jido.Chat.*` structs are canonical domain structs in runtime APIs.
3. No direct platform SDK deps in `jido_messaging`.
4. Adapter integrations happen through `Jido.Chat.Adapter` only.
5. Process tree is stable and bridge-configurable at runtime.
6. Hard break complete: no compatibility wrappers.

## First Implementation Batch (immediate)
1. Rename namespace to `Jido.Messaging.*`.
2. Add `jido_chat` dep; remove platform deps.
3. Delete channel modules/behavior.
4. Introduce `AdapterBridge` and wire outbound gateway through it.
5. Replace struct usages (`Message/Room/Participant/Content/Capabilities/MessagingTarget`) with `Jido.Chat.*`.
