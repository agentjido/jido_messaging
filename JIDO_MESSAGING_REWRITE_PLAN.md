# Jido Messaging Rewrite Plan (Synced)

Date: 2026-02-27  
Branch: `feature/phase3-server-pivot`  
Status: In Progress

## Objective
Finalize `jido_messaging` as a runtime/server package with canonical namespace
`Jido.Messaging.*`, using `Jido.Chat.*` as the canonical domain and adapter
boundary.

Hard-break policy remains active:
1. No backwards compatibility shims.
2. No legacy `JidoMessaging.*` compatibility modules.
3. No in-package Telegram/Discord SDK ownership in runtime internals.

## Current State Snapshot
1. Canonical namespace migration completed (`Jido.Messaging.*`).
2. Bridge naming migration completed (`BridgeRegistry`, `BridgePlugin`).
3. `instance_id` -> `bridge_id` routing identity hard-break completed.
4. `jido_messaging` direct deps on `jido_chat_telegram` / `jido_chat_discord` removed.
5. Inbound routing now canonicalizes via `Jido.Chat.process_event/4`.
6. Bridge runtime supervision is in place (`BridgeSupervisor` + `BridgeServer`).
7. Domain structs are canonicalized to `Jido.Chat.*` where intended.
8. Active package structs are Zoi-backed.

## Remaining Work (Priority Order)

## 1) Runtime Decoupling Polish
1. Keep runtime library free of direct platform module constants.
2. Keep platform-specific references isolated to demos/tests/docs only.
3. Continue replacing stale "channel SDK in runtime" language in docs/comments.

## 2) Topology Bootstrap and Operability
1. Keep YAML topology bootstrap for demo/control-plane onboarding.
2. Add optional validation pass for topology schema (bridge IDs, binding references).
3. Add operator docs for day-0 bringup and day-1 edits (bridge config updates).

## 3) Outbound/Ingest Conformance
1. Expand conformance tests for capability declarations vs behavior.
2. Harden event family routing coverage (`message`, `reaction`, `action`, `modal`, `slash`, assistant events).
3. Keep explicit unsupported contracts (`{:error, :unsupported}`) deterministic.

## 4) Messaging Runtime Cleanup
1. Continue removing stale demo-era assumptions in runtime APIs.
2. Tighten observability around bridge lifecycle and reconcile operations.
3. Finalize docs for dead-letter/replay metadata with bridge identity.

## Architecture (Canonical)

## Control Plane (Runtime-Editable)
1. `Jido.Messaging.BridgeConfig`
2. `Jido.Messaging.RoomBinding`
3. `Jido.Messaging.RoutingPolicy`
4. `Jido.Messaging.ConfigStore`

## Data Plane
1. `Jido.Messaging.AdapterBridge`
2. `Jido.Messaging.InboundRouter`
3. `Jido.Messaging.OutboundRouter`
4. `Jido.Messaging.Deliver`

## Runtime Process Tree
1. Root `Jido.Messaging.Supervisor`
2. Runtime services: registries, signal bus, room/agent/session/dead-letter/outbound supervisors
3. Bridge runtime: `Jido.Messaging.BridgeSupervisor` with per-bridge `BridgeServer`

## Acceptance Criteria (Completion)
1. Runtime/public docs consistently describe bridge-config-driven routing.
2. No runtime library module hard-codes `Jido.Chat.Telegram.*` or `Jido.Chat.Discord.*`.
3. Inbound/outbound paths remain canonicalized through `Jido.Chat.Adapter` + `Jido.Chat.process_event/4`.
4. Topology bootstrap path is documented and tested.
5. `mix test` and `mix quality` pass in `jido_messaging`.

