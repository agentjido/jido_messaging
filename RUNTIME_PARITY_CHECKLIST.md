# Jido.Messaging Runtime Parity Checklist

This document is the runtime-side follow-up to `jido_chat` PR `#9`.

It exists to answer a narrower question than the core package parity docs:

- `jido_chat` parity = adapter contract, canonical payloads/types, typed handles, fallback behavior
- `jido_messaging` parity = runtime orchestration, ingress, state, delivery, retries, routing, supervision

Use this checklist when evaluating whether the runtime layer matches the Chat SDK operational model closely enough for production use.

## Scope

Focus on runtime concerns that do **not** belong in `jido_chat`:

- webhook ingress and request handling
- room / participant / thread resolution
- session routing and bridge config resolution
- outbound delivery queues, retries, and backpressure
- bridge lifecycle and listener supervision
- dedupe, moderation, gating, and security checks
- runtime state durability and distributed coordination

## Runtime Parity Areas

| Area | Chat SDK expectation | `jido_messaging` target | Status | Notes |
|---|---|---|---|---|
| Webhook ingress | provider webhook request enters one runtime boundary and becomes normalized events/messages | `WebhookPlug` + `route_webhook_request/…` provide a stable ingress path | TODO | verify adapter coverage and typed outcomes |
| Subscription/session routing | follow-up messages route back to the right room/thread/session | `SessionManager`, `SessionKey`, `MsgContext`, `Ingest` preserve routing keys | TODO | especially for DM/thread edge cases |
| Overlapping message handling | queue / debounce / concurrent behavior is deterministic | runtime-level ownership, not `jido_chat` ownership | TODO | compare against current Chat SDK concurrency behavior |
| Delivery orchestration | outbound sends/edits/media go through a reliable runtime path | `Deliver` + `OutboundGateway` + `AdapterBridge` | TODO | verify retry/degrade/crash classifications |
| Backpressure and retries | bounded queues, retryable vs terminal failures | `OutboundGateway` partitioning and error classification | TODO | validate on real adapters |
| Runtime state durability | production-safe persistence and crash recovery | persistence adapter story is explicit and tested | TODO | define target adapter(s) |
| Bridge lifecycle | one runtime owns adapter listeners and health tracking | `BridgeSupervisor` / `BridgeServer` / reconnect workers | TODO | verify health and restart semantics |
| Security / moderation / gating | ingress policy decisions happen before persistence and handling | `Security`, `Moderation`, `Gating` pipeline | TODO | verify denial behavior and observability |
| Observability | sent / failed / received events are emitted consistently | `Signal`, audit logging, bridge status, dead-letter flows | TODO | define minimum production telemetry bar |

## Review Questions

Use these when doing the runtime parity pass:

1. Does ingress normalize provider payloads once, or are there duplicate parsing paths?
2. Is room/thread/session routing deterministic across replies, DMs, and proactive sends?
3. Are queueing, retry, and degradation behaviors explicit and testable?
4. Does runtime state belong in one place, or is ownership split awkwardly between `jido_chat` and `jido_messaging`?
5. Can a bridge fail, reconnect, and resume without losing routing correctness?
6. Are unsupported adapter features surfaced clearly instead of being silently dropped?
7. Are delivery outcomes observable enough to debug production failures quickly?

## Validation Plan

Minimum validation for a future runtime parity pass:

1. Core runtime unit tests
   - ingress normalization
   - route/session persistence
   - outbound gateway classification
   - media policy handling
   - bridge lifecycle transitions

2. Cross-package integration tests
   - `jido_messaging` + `jido_chat_*` adapters
   - reply continuity
   - media delivery
   - retry/degrade behavior
   - webhook ingress to outbound round-trip

3. Live adapter-backed runtime tests
   - Discord
   - Slack
   - Telegram
   - optional Mattermost later

## Current Known Gaps To Revisit

- `jido_chat` still contains lightweight `StateAdapter` / `Concurrency` hooks that likely want to migrate upward over time.
- runtime parity has not yet been described with the same precision as package parity in `jido_chat`.
- coverage/validation focus has been heavier on adapter contract behavior than on production runtime behavior.
