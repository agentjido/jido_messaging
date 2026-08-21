# RFC 0001: Durable Inbox, Outbox, and Delivery Recovery

- Status: Proposed
- Owners: Jido Messaging maintainers
- GitHub issue: [#56](https://github.com/agentjido/jido_messaging/issues/56)
- Last updated: 2026-08-20

## Summary

Jido Messaging will support two explicit delivery modes:

- `:memory` uses the current ETS queues, dedupe claims, retry state,
  idempotency cache, and dead-letter records. State can be lost when the BEAM
  stops.
- `:durable` stores inbox, outbox, attempt, idempotency, and dead-letter state
  in a persistence adapter that supports atomic delivery transactions and
  lease claims. SQLite is the first reference adapter.

Durable mode gives at-least-once processing. It gives effectively-once effects
when the provider supports an idempotency key or a read-after-write lookup.
No general system can guarantee exactly-once effects across an external
provider and a local database without a shared transaction.

This RFC does not add durable human approval flows. Approval durability stays
outside this package by design.

## Goals

- Define the durable acceptance point for inbound work.
- Make outbound queued work, attempts, and terminal failure survive restart.
- Prevent concurrent owners from completing the same leased record.
- Define duplicate-event and duplicate-send behavior.
- Recover canonical messages that remain in `:sending`.
- Keep dead-letter history durable and replayable.
- Give operators stable telemetry and repair actions.
- Keep ETS useful as a small, explicit non-durable mode.

## Non-goals

- Distributed consensus or a new cluster membership system.
- Exactly-once provider effects when the provider has no idempotency support.
- Durable agent state, workflow state, or human approvals.
- Storage of resolved bridge credentials in delivery records.
- Replacement of provider audit logs.

## Terms

- **Inbox record**: durable acceptance and processing state for one provider
  event.
- **Outbox record**: durable intent to make one provider-side effect.
- **Attempt record**: immutable result of one provider call.
- **Lease**: time-bounded ownership of work by one runtime.
- **Fencing token**: increasing integer that prevents a stale owner from
  completing work after a new owner claims it.
- **Ambiguous result**: a provider call might have succeeded, but the runtime
  did not durably record the response.

## Delivery mode and adapter capabilities

The messaging instance configuration selects `delivery_mode: :memory` or
`delivery_mode: :durable`. The default remains `:memory` for compatibility.

Durable mode requires a persistence capability named
`:transactional_delivery`. An adapter with this capability must implement:

- one transaction for canonical records and delivery records;
- unique constraints for inbox and outbox idempotency keys;
- atomic due-record claims;
- compare-and-set completion by lease owner and fencing token;
- indexed scans by state and due time;
- retention deletes in bounded batches.

Startup must fail with `{:unsupported_persistence_capability,
:transactional_delivery}` if durable mode is selected without this capability.
It must not silently use in-memory safety state.

### ETS mode

ETS implements `:memory` only. Its state machine and telemetry use the same
names as durable mode, but a BEAM restart can lose accepted or queued work.
Tests can use ETS for fast state-machine tests. Crash-recovery conformance
tests must use a durable adapter.

### SQLite mode

SQLite is the first durable reference. It uses `BEGIN IMMEDIATE` transactions,
unique indexes, and conditional updates. One active Jido Messaging writer owns
one SQLite instance database. Process or host failover is supported after the
old writer releases the database and its leases expire.

Concurrent writers against SQLite on a network file system are not supported.
A future server database adapter can support multiple active nodes with the
same lease and fencing contract.

## Inbound state machine

```text
received
   |
   v
accepted --> processing --> completed
   |             |
   |             +-------> retry_wait --+
   |                                   |
   +-------------------------------> dead
```

`received` is not durable. The durable states are:

- `accepted`: the inbox record is committed and can be acknowledged.
- `processing`: one worker owns an active lease.
- `retry_wait`: processing failed and `next_attempt_at` is in the future.
- `completed`: canonical effects and the outcome are committed.
- `dead`: retry policy ended or the input is terminally invalid.

### Inbound acceptance point

For webhook ingress, the runtime can return a success response after it commits
the inbox record. Synchronous mode can wait for `completed`, but it must not
acknowledge before `accepted` in durable mode.

For polling, gateway, or queue ingress, the adapter can commit its provider
offset after the inbox record reaches `accepted`. Provider redelivery then
finds the unique inbox record.

The inbox uniqueness key is:

```text
{instance_id, bridge_id, provider_event_id}
```

If a provider has no stable event ID, the adapter must supply a documented
deterministic fingerprint. The fingerprint includes the provider namespace and
canonical payload bytes. Time alone is not a valid identity.

### Inbound transaction boundary

The completion transaction performs these changes together:

1. Verify the inbox lease and fencing token.
2. Insert or update canonical room, participant, thread, and message records.
3. Insert any required outbox intents for committed signals or relay effects.
4. Store the normalized ingress outcome.
5. Mark the inbox record `completed`.

If the transaction rolls back, the inbox record remains claimable. A duplicate
provider event returns the stored completed outcome or observes current work.
It does not create a second canonical message.

## Outbound state machine

```text
pending --> leased --> succeeded
   ^          |
   |          +--> retry_wait --+
   |          |
   |          +--> ambiguous --> retry_wait or dead
   |          |
   +----------+--> dead

pending | retry_wait | ambiguous --> cancelled
dead --> replay creates a new generation
```

The durable states are:

- `pending`: committed intent, ready when `available_at` is due.
- `leased`: one worker owns an attempt.
- `retry_wait`: a classified retryable failure has a future due time.
- `ambiguous`: the provider effect can exist, but no success was committed.
- `succeeded`: provider identity and final result are committed.
- `dead`: retry policy ended or a terminal failure occurred.
- `cancelled`: an operator or a superseding edit stopped work before success.

The canonical message and its delivery group and outbox records are inserted in one transaction.
The canonical message starts as `:sending`. Success updates the message to
`:sent` and stores its provider message ID in the same transaction that marks
the outbox record `succeeded`. Terminal failure updates the message to
`:failed` and creates the durable dead-letter record in one transaction.

### Multi-route delivery groups

Each routing decision creates one delivery group and one outbox record for
each selected route. The group stores the routing policy revision, delivery
mode, failover order, and route set. A later routing policy change does not
change in-flight work.

For `:primary` and `:best_effort`, only the current route is active. A retryable
failure retries that route. A terminal failure activates the next route only
when the stored failover policy permits it. Success cancels routes that were
not activated. For `:broadcast`, all routes are active.

The canonical message stays `:sending` while an active route can still change
the group result. When all active routes are terminal, the message is `:sent`
if at least one route succeeded and `:failed` if no route succeeded. This
matches the current outbound router contract. Per-route provider message IDs
and failures stay on their outbox records. `Message.external_id` keeps the
first successful route ID only for compatibility; it is not the source of
truth for a multi-route delivery.

## Claims, leases, and fencing

An inbox worker claim must atomically:

1. Select a due record in `accepted` or `retry_wait`.
2. Set `state = processing`.
3. Set `lease_owner`, `lease_expires_at`, and a new `fencing_token`.
4. Increment `attempt_count` when processing starts.

An expired `processing` inbox record becomes claimable by the same atomic
operation. Inbound canonical effects are committed only with the inbox
completion, so an expired inbound lease does not create an ambiguous external
effect.

An outbox worker claim must atomically:

1. Select a due record in `pending` or `retry_wait`.
2. Set `state = leased`.
3. Set the lease owner, expiry, and a new fencing token.
4. Create a reserved attempt record. It does not increment `attempt_count` yet.

Immediately before the provider call, one transaction marks the attempt
`started`, records `provider_call_started_at`, and increments `attempt_count`.
This durable marker separates safe pre-call recovery from an ambiguous result.
An expired `leased` record with only a reserved attempt returns to its prior
due state. An expired `leased` record with a started attempt moves to
`ambiguous`; it must follow the ambiguous policy before another provider call.
It must not be claimed and sent again directly.

The owner ID is `{node_id, runtime_id, worker_id}`. `runtime_id` is a random ID
created for each runtime start. Node name alone is not sufficient.

Completion and lease extension use this condition:

```text
id = ? AND state = 'leased' AND lease_owner = ? AND fencing_token = ?
```

An update count of zero means `:lease_lost`. A stale worker must discard its
local result and must not change the canonical message.

The default lease is longer than the provider timeout plus one retry backoff.
Workers can extend a lease before a long provider call. All due-time and lease
comparisons use database UTC time when the adapter supports it. Tests use an
injected clock.

## Idempotency and delivery guarantees

The outbox uniqueness key is:

```text
{instance_id, bridge_id, operation, idempotency_key, generation}
```

Normal delivery uses generation `0`. A safe replay keeps the same provider
idempotency key and generation. A forced replay creates a new generation and
must require explicit operator intent.

| Boundary | Guarantee | Condition |
| --- | --- | --- |
| Provider event to inbox | Effectively once | Stable provider event ID or deterministic fingerprint |
| Inbox to canonical records | Effectively once | Atomic local transaction and canonical unique keys |
| Outbox worker execution | At least once | Lease expiry permits recovery after worker loss |
| Provider effect | Effectively once | Provider honors the stable idempotency key |
| Provider effect without idempotency | At least once | Duplicate effect is possible after an ambiguous result |
| `ambiguous_policy: :do_not_retry` | At most once attempt | Effect can be lost and requires operator review |

The default ambiguous policy is:

1. Query provider state when the adapter supports lookup by idempotency key.
2. Mark success if the effect is found.
3. Retry with the same idempotency key if the provider supports idempotency.
4. Otherwise move to `dead` with classification `:ambiguous_delivery`.

The default does not blindly resend to a provider that has no idempotency or
lookup support.

## Durable records

All records include `instance_id`, `inserted_at`, and `updated_at`.

### Inbox

- `id`
- `bridge_id`
- `provider_event_id`
- `payload` or encrypted payload reference
- `payload_hash`
- `state`
- `attempt_count`
- `available_at`
- lease owner, expiry, and fencing token
- normalized outcome or classified failure
- `completed_at` or `dead_at`

### Outbox

- `id`
- canonical `message_id`
- bridge, room, thread, and operation identity
- stable idempotency key and generation
- provider-safe request payload; no resolved credentials
- `state`
- priority and partition key
- retry policy snapshot
- `attempt_count` and `available_at`
- lease owner, expiry, and fencing token
- provider message ID and safe response metadata
- `succeeded_at`, `dead_at`, or `cancelled_at`

The retry policy is copied into the outbox record when the intent is created.
A later bridge configuration change does not change an existing delivery.
Secret references can be stored, but resolved values must be obtained when an
attempt starts and must not enter persisted payloads or diagnostics. See
[#52](https://github.com/agentjido/jido_messaging/issues/52).

### Attempt

- outbox or inbox record ID
- attempt number
- state: `reserved`, `started`, or `finished`
- worker and fencing identity
- reservation, provider-call start, and finish timestamps
- safe request hash
- result classification and duration
- provider request ID and retry-after value when available

Attempt records are immutable. They do not store resolved credentials or raw
provider bodies unless a separate redacted audit policy permits it.

### Dead letter

- source kind and source record ID
- final classified reason
- safe request snapshot or payload reference
- original idempotency identity and generation
- first and last failure timestamps
- replay count, last replay ID, and archive state
- retention deadline

Replay never mutates old attempt history. It either resumes a safe unchanged
outbox record or creates a linked outbox generation.

## Retention

Defaults are configurable per instance:

- completed inbox records: 7 days;
- succeeded outbox records: 30 days;
- attempt records for success: 30 days;
- dead and ambiguous records: 90 days after resolution;
- unresolved dead letters: no automatic delete;
- archived dead letters: 90 days.

Idempotency records must live at least as long as the provider redelivery and
retry window. Configuration validation rejects a shorter retention window.
Cleanup uses indexed, bounded batches and emits counts and duration telemetry.

## Recovery

Startup recovery starts after persistence and before ingress listeners accept
new work.

1. Generate a new runtime owner ID.
2. Make expired inbox leases and pre-call outbox leases claimable. Move an
   expired outbox lease with a started provider attempt to `ambiguous`. Do not
   change active leases.
3. Scan due inbox and outbox records in bounded pages.
4. Requeue records through the normal partition function.
5. Find canonical messages in `:sending` with no active outbox record.
6. Repair a missing outbox intent from stored delivery metadata, or move the
   message to `:failed` with `:orphaned_sending_message` when repair is not
   deterministic.
7. Start ingress listeners only after the first recovery scan ends.

Recovery is repeatable. It does not reset attempt counts or create new
idempotency keys. Periodic sweeps repeat the scan so missed notifications do
not leave work stranded.

## Operator API

Read actions:

- list and get inbox, outbox, attempt, and dead-letter records;
- filter by instance, bridge, room, message, state, classification, and time;
- show lease owner and expiry;
- explain why a `:sending` message is waiting.

Write actions:

- retry a due or dead record with the same idempotency identity;
- force a new replay generation with an audit reason;
- cancel pending or retrying outbound work;
- archive a resolved dead letter;
- release a lease only after it expires, unless a force action includes a
  recorded reason;
- run reconciliation and retention in bounded batches.

Every write action records actor, reason, timestamp, prior state, and new
state. Public APIs require the messaging instance. No cross-instance operator
query is available by default.

## Telemetry

Events use safe IDs and classifications. They do not include payloads, adapter
options, credentials, or raw provider errors.

- `[:jido_messaging, :inbox, :accepted]`
- `[:jido_messaging, :inbox, :duplicate]`
- `[:jido_messaging, :inbox, :claimed]`
- `[:jido_messaging, :inbox, :completed]`
- `[:jido_messaging, :inbox, :failed]`
- `[:jido_messaging, :outbox, :enqueued]`
- `[:jido_messaging, :outbox, :claimed]`
- `[:jido_messaging, :outbox, :attempted]`
- `[:jido_messaging, :outbox, :retry_scheduled]`
- `[:jido_messaging, :outbox, :ambiguous]`
- `[:jido_messaging, :outbox, :succeeded]`
- `[:jido_messaging, :outbox, :dead]`
- `[:jido_messaging, :lease, :lost]`
- `[:jido_messaging, :recovery, :completed]`
- `[:jido_messaging, :retention, :completed]`

Common measurements include duration, queue age, attempt count, records
scanned, records repaired, and records deleted. Common metadata includes safe
record IDs, instance module, bridge ID, operation, classification, partition,
and outcome.

Required gauges are due inbox count, due outbox count, oldest due age, active
leases, ambiguous count, dead-letter count, and orphaned `:sending` count.

## Compatibility and migration

Existing instances stay in `:memory`. No automatic change gives a false
durability guarantee.

The first durable migration creates empty delivery tables and capabilities.
It does not infer old in-memory queue or dedupe state. On enablement, recovery
scans persisted `:sending` messages and repairs only records with enough stable
delivery metadata. Other messages become classified failures for operator
review.

The existing in-memory `DeadLetter` API remains available in memory mode. In
durable mode, the same API delegates to the delivery store. Existing list,
replay, archive, and purge response shapes remain compatible where possible.

## Conformance and failure tests

The durable adapter contract must test:

- atomic acceptance and duplicate provider events;
- rollback between canonical and delivery record writes;
- two concurrent claims with one winner;
- lease expiry, renewal, fencing, and stale completion;
- crash before provider call, during call, after response, and after commit;
- provider idempotency and ambiguous delivery policies;
- restart recovery of `:sending` messages;
- dead-letter replay generations and audit history;
- retention bounds and unresolved dead-letter protection;
- instance isolation;
- absence of marker secrets from storage, logs, telemetry, and errors.

The test clock and provider adapter are deterministic. Crash tests terminate
the worker process at named barriers and restart the full messaging instance.

## Implementation sequence

1. Extend the persistence conformance work in
   [#50](https://github.com/agentjido/jido_messaging/issues/50) with delivery
   transactions, claim, lease, fencing, and retention contracts.
2. Build on commit-aware inbound dedupe from
   [#45](https://github.com/agentjido/jido_messaging/issues/45) to add durable
   inbox acceptance and completion.
3. Add durable outbox creation, workers, provider idempotency, and attempt
   records to the outbound gateway.
4. Replace in-memory dead-letter state with a delivery-store implementation in
   durable mode, while preserving the public API.
5. Extend startup reconciliation from
   [#49](https://github.com/agentjido/jido_messaging/issues/49) to recover due
   records and orphaned `:sending` messages before listener startup.
6. Add operator APIs, telemetry, retention, migration tools, and crash-barrier
   conformance tests.

Each implementation pull request must keep ETS memory mode green and must add
SQLite restart tests. The implementation can ship behind an experimental
configuration flag until all recovery and conformance tests pass.

Creation of new implementation issues is deferred until this RFC is accepted.
This avoids publishing storage contracts before maintainers approve the record
and guarantee model. The linked foundation issues above remain the current
implementation dependencies. After acceptance, maintainers will create one
issue for each of steps 1 through 6 and link them from
[#56](https://github.com/agentjido/jido_messaging/issues/56) before durable mode
implementation starts.

## Rejected alternatives

### Treat SQLite messages as an outbox

A canonical message does not contain lease, attempt, retry, ambiguity,
operation, or replay-generation state. Adding all of that state to the message
would join the domain record to one transport workflow and would make edits and
multi-route delivery unclear.

### Acknowledge inbound work after an in-memory queue insert

This loses accepted work on process failure. Durable mode acknowledges after
the inbox commit.

### Retry every ambiguous outbound call

This can duplicate provider messages when the provider has no idempotency
support. The adapter capability and configured ambiguous policy decide the
action.

### Use node ownership without leases

A stopped or partitioned node can retain stale ownership. Time-bounded leases
with fencing allow recovery and reject stale completion.

### Put durable approvals in the delivery store

Human approval is workflow state, not transport delivery state. This package
does not own it.
