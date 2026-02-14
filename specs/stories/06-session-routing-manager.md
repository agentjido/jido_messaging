# Story 06: Session Routing Manager

## Objective
Add a partitioned, stateful session routing manager for deterministic route resolution across channel/instance/room/thread scopes.

## Problem / Gap
`SessionKey` provides deterministic derivation but no managed state for last successful route, fallback selection, stale-route handling, or concurrent route updates.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 03: Outbound Gateway.
- Story 04: Ingest Policy Pipeline.

## In Scope
- Define session route context model and API.
- Implement partitioned session manager workers keyed by session hash.
- Add TTL/eviction and stale-route fallback behavior.
- Integrate ingest updates and outbound route resolution.
- Emit route-resolution telemetry.

## Out of Scope
- Cross-node distributed consensus for routes.
- Product-specific routing heuristics beyond deterministic defaults.
- Directory resolution workflows.

## Public API / Interface / Type Changes
- Add `JidoMessaging.SessionManager` API (`set`, `get`, `resolve`, `prune`).
- Add runtime config for partition count, TTL, max entries per partition.
- Add resolution result types including fallback and stale indicators.

## Implementation Tasks
- Implement partitioned manager pool under dedicated supervisor.
- Add bounded ETS/backing store per partition with cleanup scheduling.
- Update ingest to write route context on inbound success.
- Update outbound gateway to resolve route context prior to dispatch.
- Implement stale-route fallback policy and route-confidence markers.
- Add telemetry for hits, misses, fallbacks, evictions, and stale-route detections.

## Acceptance Criteria
- Route state is partitioned and does not rely on a single global process.
- Outbound route resolution is deterministic for repeated session traffic.
- TTL and eviction prevent unbounded in-memory growth.
- Fallback logic selects valid alternatives when primary route is stale.
- Route manager worker crashes are isolated and recover via supervisor without global outage.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/session_key_test.exs
mix test test/jido_messaging/messaging_target_test.exs
mix test test/jido_messaging/deliver_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add route CRUD, TTL expiry, eviction, and fallback ordering tests.
- Add partition-routing tests for stable hashing behavior.
- Integration tests:
- Add ingest->session update->outbound resolve flows.
- Add concurrent route update tests to validate determinism.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Concurrency tests must be deterministic and non-flaky.

## Rollout / Observability
- Enable with in-memory partitioned backend default.
- Emit per-partition pressure metrics and fallback rates.
- Provide tuning guidance for partition count and TTL.

## Risks / Mitigations
- Risk: Partition imbalance under skewed keys.
- Mitigation: configurable hash strategy and partition-load telemetry.
- Risk: Stale routes cause incorrect delivery.
- Mitigation: freshness checks and fallback validation before send.
- Risk: Eviction causes route thrashing.
- Mitigation: adaptive TTL guidance and hit/miss monitoring.
