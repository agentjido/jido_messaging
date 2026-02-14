# Story 07: Media Pipeline

## Objective
Make media a first-class pipeline feature with bounded processing, capability-aware fallback, and failure isolation.

## Problem / Gap
Media structs exist but ingest and delivery are mostly text-oriented, and there is no uniform policy for media parsing, dispatch, limits, fallback, and failure behavior.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 01: Channel Contract v2.
- Story 03: Outbound Gateway.
- Story 06: Session Routing Manager.

## In Scope
- Normalize inbound media payloads into canonical content blocks.
- Add outbound media operations through gateway.
- Enforce media policy (type, size, limits) with deterministic outcomes.
- Add fallback behavior when channel lacks required capabilities.
- Ensure media handling uses bounded resources.

## Out of Scope
- Persistent blob storage/CDN design.
- Transcoding/transformation engines.
- Malware scanning infrastructure.

## Public API / Interface / Type Changes
- Add gateway media operation envelopes.
- Add normalized media metadata fields in message context/content.
- Add media-policy configuration schema (size/type/count limits).
- Add fallback result metadata for downgrade decisions.

## Implementation Tasks
- Extend first-party channel transforms for inbound media extraction.
- Implement outbound media adapters in gateway with capability checks.
- Add preflight media policy validation and error classification.
- Add deterministic text fallback or reject behavior for unsupported channels.
- Add bounded buffering and timeout safeguards for media-related operations.
- Add telemetry for media accept/reject/fallback and payload size distribution.

## Acceptance Criteria
- Supported inbound media payloads normalize correctly into canonical content.
- Outbound media dispatch goes through gateway and respects capability checks.
- Unsupported media paths follow deterministic fallback or reject policy.
- Media processing does not introduce unbounded memory growth.
- Media-related failures are isolated and classified without destabilizing runtime.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/capabilities_test.exs
mix test test/jido_messaging/ingest_test.exs
mix test test/jido_messaging/deliver_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add media parse tests for each first-party channel mapper.
- Add policy validation tests for size/type/count limits and error classes.
- Integration tests:
- Add inbound media->persist scenarios.
- Add outbound unsupported-media fallback scenarios.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Media tests must be deterministic and avoid external network dependence.

## Rollout / Observability
- Roll out with conservative media limits by default.
- Emit metrics for media throughput, reject reasons, and fallback counts.
- Document per-channel media support matrix.

## Risks / Mitigations
- Risk: Large payloads degrade node performance.
- Mitigation: strict limits and early rejection.
- Risk: Channel-specific media quirks cause parsing drift.
- Mitigation: fixture-driven parser tests and canonical normalization assertions.
- Risk: Fallback obscures delivery limitations.
- Mitigation: explicit fallback markers in metadata and telemetry.
