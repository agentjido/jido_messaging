# Story 00: Runtime Topology And SLOs

## Objective
Define the runtime topology, failure-domain boundaries, restart strategies, and measurable SLOs that all subsequent stories must implement against.

## Problem / Gap
Without explicit topology and SLO constraints, subsequent stories can independently add processes and interfaces that are correct in isolation but fail to scale or align with OTP failure semantics when combined.

## Dependencies
- None. This is the foundation for all stories.

## In Scope
- Define canonical supervisor tree shape for messaging instances.
- Define crash policy matrix for critical components.
- Define restart strategies and restart intensity defaults per subtree.
- Define sharding and partitioning rules for hot-path workers.
- Define baseline SLOs and acceptance load profiles.
- Define global observability dimensions for runtime and queue health.

## Out of Scope
- Implementing channel-specific features.
- Introducing external distributed data stores.
- Building dashboards themselves.

## Public API / Interface / Type Changes
- Add architecture spec for standard supervisor children and ownership roles.
- Add typed crash-policy matrix (fatal, recoverable, degradable).
- Add runtime config schema for restart intensities, queue bounds, and SLO thresholds.
- Add telemetry naming conventions for latency, throughput, queue depth, and restart events.

## Implementation Tasks
- Document canonical subtree layout for supervisor, runtime, room, instance, and sender domains.
- Define `one_for_one` vs `rest_for_one` decisions for each subtree and why.
- Define key-based partitioning rules (instance_id, room_id, session_key) for scalable worker fanout.
- Define bounded queue policies and pressure threshold levels.
- Define failure matrix covering worker crash, dependency timeout, repeated startup failures, and poison-message behavior.
- Define SLO baselines and per-story validation expectations.

## Acceptance Criteria
- A single authoritative topology specification exists and is referenced by all subsequent stories.
- Every future runtime component category has an assigned supervisor strategy and restart-intensity rule.
- Crash matrix defines which failures should crash workers, which should be retried, and which should degrade.
- Partitioning policy avoids singleton bottlenecks for expected hot paths.
- SLO baselines are measurable and mapped to telemetry dimensions.

## Completion Validation
Run all commands from repository root:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

## Test Maintenance
- Unit tests:
- Add tests for runtime config schema validation and default bounds.
- Add tests for crash policy classification helper modules.
- Integration tests:
- Add supervisor restart-behavior tests proving isolation boundaries.
- Add bounded-queue behavior tests for pressure thresholds.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Topology tests must be deterministic and not depend on external services.

## Rollout / Observability
- Publish topology and crash-matrix docs before implementing Story 01 changes.
- Emit startup-time telemetry summarizing configured restart intensities and queue bounds.
- Require every subsequent story to include explicit references to these runtime conventions.

## Risks / Mitigations
- Risk: Over-constraining topology reduces flexibility.
- Mitigation: allow bounded override points with documented defaults.
- Risk: SLO targets are unrealistic for current infrastructure.
- Mitigation: define baseline targets plus tuning guidance and review checkpoints.
- Risk: Team inconsistency in applying crash matrix.
- Mitigation: add lint-like review checklist requiring explicit crash policy in each story.
