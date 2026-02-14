# Story 11: Resilience & Operations

## Objective
Implement dead-letter, replay, and backpressure controls with measurable recovery behavior and OTP-aligned fault containment.

## Problem / Gap
Retries and health signals exist, but there is no complete operational model for terminal failures, replay safety, load-shedding, and recovery SLOs.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 03: Outbound Gateway.
- Story 05: Security Boundary.
- Story 10: Plugin Manifest Discovery.

## In Scope
- Add dead-letter sink and record schema.
- Capture terminal inbound/outbound failures in dead-letter storage.
- Add replay service with idempotency guards.
- Add queue pressure thresholds and throttling/load-shedding controls.
- Add operational telemetry and runbook requirements.

## Out of Scope
- Cross-region failover architecture.
- External SIEM integration pipelines.
- Fully automatic replay without operator controls.

## Public API / Interface / Type Changes
- Add dead-letter API (`list`, `get`, `replay`, `archive`, `purge`).
- Add dead-letter record type with correlation, reason class, and payload references.
- Add pressure-policy config for queue bounds and throttling actions.
- Add recovery telemetry schema for replay and pressure transitions.

## Implementation Tasks
- Implement dead-letter persistence abstraction and retention controls.
- Integrate terminal failure capture points in ingest and outbound gateway flows.
- Implement replay workers partitioned by dead-letter item key.
- Add replay idempotency checks and side-effect guards.
- Implement pressure thresholds with degrade/drop strategies per policy.
- Document incident response and replay runbooks.

## Acceptance Criteria
- Terminal failures are captured with sufficient context for diagnosis and replay.
- Replay operations are idempotent and safe against duplicate side effects.
- Queue pressure controls prevent unbounded growth under sustained load.
- Worker crashes during replay are isolated and recoverable by supervisor strategy.
- Operational telemetry clearly shows pressure, drop, and replay outcomes.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/sender_test.exs
mix test test/jido_messaging/sender_idempotency_test.exs
mix test test/jido_messaging/integration_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add dead-letter schema and retention policy tests.
- Add replay idempotency and invalid-state rejection tests.
- Add pressure policy threshold and action-selection tests.
- Integration tests:
- Add forced-failure capture and replay-recovery scenarios.
- Add sustained-load pressure tests validating bounded queue behavior.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Reliability tests must be deterministic and stable in CI.

## Rollout / Observability
- Roll out in phases: capture -> replay -> aggressive pressure controls.
- Emit telemetry for dead-letter writes, replay attempts, replay outcomes, and pressure state transitions.
- Publish runbook steps for triage, replay, and cleanup.

## Risks / Mitigations
- Risk: Replay causes duplicate external side effects.
- Mitigation: idempotency keys and replay guard enforcement.
- Risk: Dead-letter store grows without bounds.
- Mitigation: retention windows and archive/purge operations.
- Risk: Load shedding drops critical messages.
- Mitigation: priority-aware throttle policy and explicit drop telemetry.
