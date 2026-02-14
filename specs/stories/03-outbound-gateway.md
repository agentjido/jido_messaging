# Story 03: Outbound Gateway

## Objective
Introduce a unified outbound gateway for send/edit/chunk/retry/rate-limit behavior with partitioned workers and explicit crash boundaries.

## Problem / Gap
Delivery currently calls channels directly, while queue/retry behavior is separate. This creates inconsistent error handling, rate governance, and observability.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 02: Instance Lifecycle Runtime.

## In Scope
- Add gateway request/response envelopes.
- Route `Deliver` through gateway.
- Partition outbound workers by stable routing key (instance_id + external_room_id hash).
- Integrate queue/idempotency and bounded retries.
- Add rate-limit and chunking policy hooks.
- Normalize outbound errors into retryable/non-retryable/fatal classes.

## Out of Scope
- Dead-letter and replay implementation.
- Ingest policy integration.
- Full media upload orchestration.

## Public API / Interface / Type Changes
- Add `JidoMessaging.OutboundGateway` API with typed envelopes.
- Add partitioning config (`partition_count`, hash strategy) and queue bounds.
- Add error taxonomy type for retry decisions and operational reporting.
- Add gateway telemetry schema including queue depth, attempt count, and final disposition.

## Implementation Tasks
- Implement gateway facade and partitioned worker pool.
- Move delivery send/edit path behind gateway adapter.
- Integrate sender idempotency and retry logic per partition.
- Add bounded mailbox/queue behavior and backpressure signals.
- Add channel rate-limit hooks with per-channel defaults.
- Add retry classification mapping from channel/provider errors.

## Acceptance Criteria
- All outbound traffic flows through gateway APIs.
- Outbound workers are partitioned and no global singleton becomes a hot-path bottleneck.
- Queue bounds and pressure signaling prevent unbounded growth.
- Retry behavior is deterministic and classified by error category.
- Delivery telemetry includes partition and pressure context.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/sender_test.exs
mix test test/jido_messaging/sender_idempotency_test.exs
mix test test/jido_messaging/deliver_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add gateway contract tests for request validation, error classification, and partition routing.
- Add bounded queue tests for pressure thresholds.
- Integration tests:
- Add deliver-through-gateway tests for success, retry, and give-up flows.
- Add concurrency tests proving partitioned throughput and absence of singleton contention.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Concurrency tests must be deterministic and non-flaky.

## Rollout / Observability
- Roll out with gateway enabled and partition metrics visible.
- Emit per-partition queue depth, retry attempts, and latency histograms.
- Provide operator tuning guidance for partition count and queue limits.

## Risks / Mitigations
- Risk: Incorrect partition key causes uneven load.
- Mitigation: configurable hash key and partition-balance telemetry.
- Risk: Backpressure drops important messages.
- Mitigation: policy hooks for priority routing and drop reporting.
- Risk: Retry classification misses provider edge cases.
- Mitigation: fallback classification with raw provider reason capture.
