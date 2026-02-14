# Story 04: Ingest Policy Pipeline

## Objective
Enforce gating and moderation directly in ingest with bounded execution, explicit outcomes, and OTP-safe failure isolation.

## Problem / Gap
Gating/moderation utilities exist but are not mandatory in ingest. Policy checks can be bypassed or inconsistently applied, and no timeout/isolation constraints protect ingest throughput.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 01: Channel Contract v2.
- Story 03: Outbound Gateway.

## In Scope
- Build `MsgContext` early and run gating then moderation in deterministic order.
- Add policy timeout budgets and failure mode classification.
- Prevent denied messages from persistence/signals/agent dispatch.
- Persist modified/flagged results with audit metadata.
- Emit policy decision telemetry.

## Out of Scope
- Sender identity cryptographic verification logic.
- Outbound payload sanitization.
- Session-routing persistence.

## Public API / Interface / Type Changes
- Extend ingest API options for `:gaters`, `:moderators`, and timeout settings.
- Add explicit ingest outcome tuples for allow/deny/modify/flag and timeout/failure classes.
- Add policy decision metadata fields to context/message metadata.

## Implementation Tasks
- Refactor ingest pipeline ordering: dedupe -> context build -> gating -> moderation -> persistence -> signals.
- Execute gating/moderation with bounded timeouts to avoid hot-path blocking.
- Classify policy execution failures as recoverable deny or operational failure per configured policy.
- Ensure denied messages do not reach room server or agent triggers.
- Persist moderation flags and transformed payload metadata.
- Add policy telemetry dimensions: module, stage, outcome, elapsed_ms, reason.

## Acceptance Criteria
- Gating/moderation is mandatory when configured and runs in deterministic order.
- Policy execution cannot block ingest indefinitely due to bounded timeout handling.
- Denied messages are not persisted and do not emit message-added signals.
- Modified/flagged outcomes are persisted with auditable metadata.
- Policy execution failures follow configured crash/deny/degrade behavior explicitly.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/gating_test.exs
mix test test/jido_messaging/moderation_test.exs
mix test test/jido_messaging/ingest_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add tests for ingest outcome variants and timeout classification.
- Add tests for short-circuit behavior and metadata preservation.
- Integration tests:
- Add allow/deny/modify/flag end-to-end ingest scenarios.
- Add timeout/failure scenarios proving ingest remains responsive and isolated.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Existing ingest and signal tests remain green.

## Rollout / Observability
- Roll out with no-op defaults if no policy modules configured.
- Emit telemetry for policy latency and denial rates by module.
- Document recommended timeout budgets for policy modules.

## Risks / Mitigations
- Risk: Policy modules add latency spikes.
- Mitigation: strict timeout budgets and stage latency telemetry.
- Risk: Policy failure handling becomes inconsistent.
- Mitigation: centralized classification helper and contract tests.
- Risk: False-deny impacts user experience.
- Mitigation: configurable deny/degrade behavior and decision auditing.
