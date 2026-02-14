# Story 02: Instance Lifecycle Runtime

## Objective
Make instance runtime authoritative for channel lifecycle, supervised worker startup, reconnect behavior, and crash isolation boundaries.

## Problem / Gap
`InstanceSupervisor` and `InstanceServer` do not yet fully enforce channel child orchestration, restart strategy choices, or reconnect governance based on OTP process boundaries.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 01: Channel Contract v2.

## In Scope
- Implement channel child-spec startup path in instance trees.
- Apply explicit supervisor strategies and restart intensity defaults per subtree.
- Add reconnect policy with bounded backoff and jitter.
- Add heartbeat/probe scheduling and classify outcomes as recoverable/fatal/degraded.
- Ensure clean stop semantics and no orphan workers.

## Out of Scope
- Outbound gateway abstraction.
- Ingest policy wiring.
- Plugin manifest loading.

## Public API / Interface / Type Changes
- Add channel instance child-provider contract wiring into `InstanceSupervisor`.
- Extend instance status payload with restart counts, reconnect attempt counters, and current child health summary.
- Add lifecycle event telemetry schema including restart reason classification.

## Implementation Tasks
- Implement child-spec resolution and startup in `start_instance_tree`.
- Apply explicit supervisor strategy choices documented in Story 00.
- Implement reconnect loop worker with bounded retry policy.
- Integrate heartbeat probes via adapter contracts with timeout budgets.
- Add startup-failure policy deciding when to crash subtree vs degrade functionality.
- Update health snapshot fields to include pressure and restart markers.

## Acceptance Criteria
- Starting an instance starts expected channel workers and reports health.
- Recoverable connection failures trigger bounded reconnect behavior.
- Repeated fatal startup failures escalate per configured restart intensity and are observable.
- Stopping an instance cleanly terminates all children in deterministic order.
- No single child crash causes unrelated subtree collapse.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/instance_server_test.exs
mix test test/jido_messaging/instance_supervisor_test.exs
mix test test/jido_messaging/health_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add tests for reconnect backoff calculations and escalation logic.
- Add tests for startup failure classification and restart policy selection.
- Integration tests:
- Add instance lifecycle tests for start, recoverable disconnect, fatal loop, and graceful shutdown.
- Add process-isolation tests proving non-related workers survive targeted crashes.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- No dialyzer regressions or new ignore entries.

## Rollout / Observability
- Roll out lifecycle orchestration with telemetry-first visibility.
- Emit transition and restart metrics keyed by instance_id and channel_type.
- Publish restart-intensity defaults and tuning guidance.

## Risks / Mitigations
- Risk: Reconnect storm under provider outage.
- Mitigation: bounded retry, jitter, and escalation to degraded state.
- Risk: Incorrect supervisor strategy causes cascade failures.
- Mitigation: explicit strategy tests and crash simulation scenarios.
- Risk: Probe checks become blocking.
- Mitigation: bounded async probes with timeout classification.
