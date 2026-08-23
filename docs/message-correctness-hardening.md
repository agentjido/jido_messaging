# Message Correctness Hardening

This document records the message correctness work for the release after 1.1.1.
All prerequisite pull requests are merged.

## Corrected guarantees

`jido_messaging` now gives these guarantees:

- An ingest deduplication key is committed only when the message write succeeds.
- A bridge uses the configured adapter module and adapter options.
- The runtime restores enabled bridge workers from persistence after a restart.
- SQLite records are isolated by messaging instance when instances share one database file.
- SQLite creates an external binding as one atomic operation.
- PostgreSQL is the production persistence recommendation. Its instance-scoped
  keys, transactions, and binding constraints support concurrent writers.
- Canonical participant identities are scoped by bridge.
- Message pagination uses stable opaque cursors with defined invalid-cursor errors.
- Bridge configuration stores secret references, not raw credentials. A configured resolver reads each secret at the operation boundary.
- `jido_ai` is optional. The core package can compile and run without it.
- Participant transcript queries use an explicit scope and stable identity rules.
- Ingest maps stable provider author data to canonical participants.

Durable inbox and outbox delivery is not part of these guarantees. The durable delivery RFC defines that later work. Human approval durability stays outside this package.

## Pull request map

| Priority | Issue | Pull request | Result |
| --- | --- | --- | --- |
| P0 | [#45](https://github.com/agentjido/jido_messaging/issues/45) | [#58](https://github.com/agentjido/jido_messaging/pull/58) | Commit-aware ingest deduplication |
| P0 | [#46](https://github.com/agentjido/jido_messaging/issues/46) | [#59](https://github.com/agentjido/jido_messaging/pull/59) | Selected bridge adapter configuration |
| P1 | [#49](https://github.com/agentjido/jido_messaging/issues/49) | [#60](https://github.com/agentjido/jido_messaging/pull/60) | Startup bridge reconciliation |
| P1 | [#54](https://github.com/agentjido/jido_messaging/issues/54) | [#61](https://github.com/agentjido/jido_messaging/pull/61) | Stable message cursor pagination |
| P1 | [#47](https://github.com/agentjido/jido_messaging/issues/47) | [#62](https://github.com/agentjido/jido_messaging/pull/62) | SQLite instance isolation |
| P1 | [#48](https://github.com/agentjido/jido_messaging/issues/48) | [#63](https://github.com/agentjido/jido_messaging/pull/63) | Atomic SQLite external bindings |
| P1 | [#53](https://github.com/agentjido/jido_messaging/issues/53) | [#64](https://github.com/agentjido/jido_messaging/pull/64) | Bridge-scoped participant identity |
| P1 | [#50](https://github.com/agentjido/jido_messaging/issues/50) | [#65](https://github.com/agentjido/jido_messaging/pull/65) | Reusable persistence conformance contract |
| P1 | [#52](https://github.com/agentjido/jido_messaging/issues/52) | [#66](https://github.com/agentjido/jido_messaging/pull/66) | Operation-time bridge secret resolution |
| P2 | [#51](https://github.com/agentjido/jido_messaging/issues/51) | [#67](https://github.com/agentjido/jido_messaging/pull/67) | Optional `jido_ai` integration |
| P2 | [#55](https://github.com/agentjido/jido_messaging/issues/55) | [#68](https://github.com/agentjido/jido_messaging/pull/68) | Scoped participant transcripts |
| P2 | [#56](https://github.com/agentjido/jido_messaging/issues/56) | [#69](https://github.com/agentjido/jido_messaging/pull/69) | Durable inbox and outbox RFC |
| Follow-up | — | [#71](https://github.com/agentjido/jido_messaging/pull/71) | Stable author identity during ingest |

## Merge record

The work merged in this order:

1. Focused correctness changes: #58, #59, #60, #61, #62, and #64.
2. Dependent SQLite and runtime changes: #63, #66, #67, and #68.
3. The durable delivery RFC: #69.
4. The stable author follow-up: #71.
5. The persistence conformance contract: #65.
6. These release notes: #70.

## Compatibility notes

- Bridge credentials in raw configuration are rejected. Replace them with `secret_refs` and configure a secret resolver.
- A shared SQLite database now requires a stable messaging `instance_id`. Existing unscoped data needs a migration or an explicit legacy namespace.
- Participant identity keys now include the bridge scope. Existing cross-bridge participant IDs need mapping during migration.
- Message cursors are opaque. Consumers must not parse them and must handle the defined invalid-cursor error.
- Applications that use `jido_ai` must add it as their own dependency and can use the shipped example integration.
- The current memory delivery path remains non-durable. A successful in-memory enqueue does not give a restart guarantee.

## Verification gates

The release must continue to pass these gates:

- Run the persistence conformance contract against ETS, SQLite, and PostgreSQL.
- Run the restart reconciliation tests in CI.
- Run the SQLite concurrency and shared-file isolation tests in CI.
- Run legacy SQLite migration races and participant binding claim races in CI.
- Run PostgreSQL migration, cross-pool binding, receipt concurrency, restart,
  and instance-isolation tests in CI.
- Confirm that adapter mismatch tests stop credentials before provider code runs.
- Confirm that secret migration tests find no resolved marker values in durable storage or diagnostics.
- Run core tests without `jido_ai`, and run the optional integration lane with `jido_ai`.
- Run transcript parity tests for SQL-bounded pages, nullable timestamps, and nested projection scope checks.
- Confirm that the durable delivery RFC has accepted follow-up issues or an explicit deferred decision.
- Confirm that the corrected guarantees remain true on `main`.
