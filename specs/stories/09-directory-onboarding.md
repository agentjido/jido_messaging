# Story 09: Directory & Onboarding

## Objective
Add scalable directory resolution and onboarding state orchestration for identity bootstrap and pairing workflows.

## Problem / Gap
Participant and room binding resolution is currently event-driven from inbound IDs. There is no generalized directory or onboarding coordinator for lookup, pairing, and resumable flow control.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 06: Session Routing Manager.
- Story 08: Command & Mention Normalization.

## In Scope
- Define directory adapter contracts for lookup/search.
- Define onboarding state machine and transition rules.
- Implement onboarding coordinator with resumable flows.
- Persist onboarding/pairing metadata with idempotent transition semantics.
- Emit onboarding telemetry and audit metadata.

## Out of Scope
- UI implementation for onboarding.
- CRM synchronization integrations.
- Enterprise IAM/SSO architecture.

## Public API / Interface / Type Changes
- Add `JidoMessaging.Directory` behavior for user/group search and lookup.
- Add onboarding API and state model (`start`, `advance`, `resume`, `cancel`, `complete`).
- Add typed transition result envelopes including retry/degrade/fatal classes.
- Extend adapter/storage interfaces for onboarding and pairing persistence.

## Implementation Tasks
- Implement directory behavior and default adapter contracts.
- Implement onboarding state machine with explicit transition guards.
- Add idempotency keys for transition actions to avoid duplicate side effects.
- Add supervisor-managed onboarding workers partitioned by onboarding_id.
- Integrate telemetry for start, transition, completion, and failure classes.
- Document onboarding API semantics and transition guarantees.

## Acceptance Criteria
- Directory lookup/search is available through a unified API.
- Onboarding transitions are deterministic, validated, and idempotent.
- Interrupted onboarding flows can resume from persisted state.
- Worker crashes in onboarding flows are isolated and recoverable via supervisor strategy.
- Onboarding lifecycle metrics and audit metadata are emitted consistently.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/messaging_target_test.exs
mix test test/jido_messaging/room_server_features_test.exs
mix test test/jido_messaging/integration_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add directory adapter contract tests and ambiguous-match handling tests.
- Add onboarding transition validation and idempotency tests.
- Integration tests:
- Add end-to-end onboarding flow tests for start/advance/resume/complete.
- Add crash-and-recover scenarios proving state continuity.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Onboarding transition tests must be deterministic.

## Rollout / Observability
- Roll out onboarding APIs behind explicit usage paths.
- Emit transition-latency and failure-class telemetry.
- Publish runbook for diagnosing stalled onboarding flows.

## Risks / Mitigations
- Risk: Ambiguous directory matches create incorrect pairing.
- Mitigation: strict ambiguity errors and explicit operator resolution flow.
- Risk: State-machine edge cases cause stuck flows.
- Mitigation: exhaustive transition tests and timeout-based recovery hooks.
- Risk: High onboarding volume creates bottlenecks.
- Mitigation: partitioned worker model and queue pressure instrumentation.
