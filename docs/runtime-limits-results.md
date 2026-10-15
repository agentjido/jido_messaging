# Runtime limits: C6–C14 results

Date: 2026-10-15. Goal: complete the runtime limits checkpoints while retaining
the public API, payload validation, stored records, and request commit rules.
The [checkpoint plan](plans/2026-10-15-runtime-limits-checkpoints.md) records each
change, local check, and CI result. No package merge or publication is included.

## Changes

| Checkpoints | Result |
| --- | --- |
| C6 | Private subscription workers restore future Bus delivery after loss. |
| C7–C8e | Registry failures stop only their owned groups. Desired workers restore without adopting external registrations. Runtime and request ownership survive. |
| C9 | Private SQLite history retains IDs without an all-ID memory index. Cache is bounded to 1,000 entries or 16 MiB encoded data. |
| C10 | Runtime-owned Chat bindings share this backend. Standalone and external binding ownership stays unchanged. |
| C11 | Private prepare, invoke, and complete phases keep validation, ledger claims, and resource creation with the owner. |
| C12 | Monitored workers run provider calls. Retry and pressure waits use timers. The coordinator stays responsive and retains one active job. |
| C13 | Atomic generation-bound permits precede mailbox submission. Reserved, queued, and active jobs together stay within capacity. Overload recording uses a bounded ring. |
| C14 | Combined fault checks and repeated retention/queue measurements verify the boundaries together. |

## Combined failures

Two barrier tests cover Bus loss during a held handler, bridge registry loss
during provider work, store-worker loss after an external effect, and timeout of
an accepted queued caller. Runtime stays alive, the subscription recovers once,
and the old exact request remains unknown without another provider call. The
accepted queued job still runs once after its caller times out. Permits drain to
zero. A second scenario combines instance registry replacement with Bus loss and
caller timeout. Old provider work stops before a new generation accepts work;
old permits cannot free new work. An unstarted queued ID can be submitted after
recovery. The uncertain active ID cannot run again.

## Measurements

The 100,000-request run keeps one 2,552-byte ETS locator and a 1,000-entry cache
with 340,000 encoded bytes. Disk plus WAL uses 45,072,080 bytes. SQLite allocator
use is 2,231,136 bytes, with a 2,243,000-byte peak. The oldest exact result replays
after cache eviction and store-worker replacement. The write workload takes
18.908 s. It trades ETS-only speed for recorded claim/completion boundaries.
Whole-VM BEAM growth is not lower; cold code/application loading is included.
See [retention details](request-retention-measurement.md) and
[raw data](benchmarks/c14-retention.json).

Five 10,000-call bursts with capacity 64 keep one active job and 63 queued jobs.
Each rejects 9,937 calls before provider release and drains to zero permits.
Rejection p95 is 0.227–0.261 ms; p99 is 0.342–0.589 ms. The suspended-DeadLetter
trial has p99 0.387 ms. The repeated C5 workload rejects public overflow within
0.988 ms, compared with 102.9–109.6 ms after the original extraction. Accepted
calls still wait for completion. A caller timeout does not cancel accepted work.
The first cold C13 run exposed a timestamp code-loading delay; startup now loads
those modules before concurrent rejection. See [queue details](outbound-queue-measurement.md)
and [raw data](benchmarks/c14-queue.json).

## Verification

| Check | Result |
| --- | --- |
| Messaging full suite | 2,355 passed, including PostgreSQL, integration, and story checks |
| Messaging production coverage | 12,001/13,299 lines (90.2%) |
| Chat full suite | 402 passed |
| Chat production coverage | 2,429/2,651 lines (91.6%) |
| C14 contract baseline | 160 modules unchanged: exports, defaults, structs, callbacks, and Signal schemas |
| Format, compilation, and static checks | Passed; warnings as errors and 16 Credo checks |
| C13 CI | 22 passed, one expected skip on `a4b0fcd` |
| Final C14 CI | Pending delivery to [Messaging PR 109](https://github.com/agentjido/jido_messaging/pull/109) |
| Chat CI | 20 passed, one expected skip on `9a07c7e` |

The only C14 source addition is the combined-failure test file. Production source
is unchanged from C13. The local benchmark extension was moved to the ignored
checkpoint backup. The isolated PostgreSQL check server is stopped after tests.
Existing user deletions and untracked Chat plans remain unchanged. CHANGELOG is
unchanged. No merge or package publication was performed.

## Remaining limits

* History disk use grows with unique IDs. No expiry releases a request ID.
* Runtime or VM restart ends the replay retention contract. No durable
  exactly-once delivery is claimed.
* Externally registered bindings retain their creator's backend and resources.
* Bus recovery restores future delivery. Events missed during downtime are not
  replayed. Handler observations can be lost when their owner stops.
* Public calls can wait for configuration or routing before queue admission.
  With ConfigStore delayed by 100 ms, public total time is 103.056 ms; prebuilt
  admission is 0.033 ms. User telemetry callbacks can also delay callers.
* Queue capacity bounds admitted gateway jobs, including reservations and retry
  waits. It does not bound caller processes, arbitrary control messages, payload
  bytes, or direct Execution, ChatActions, Streaming, and Sender paths.
* DeadLetter pending and stored records each have the existing max_records
  bound. Older records can be trimmed. Its volatile records can be lost on
  owner restart. Resource data retains its existing owner and TTL limits.

Unknown outcomes stay held and are not automatically retried. Public error
shapes and canonical stored records remain unchanged. The new phase and backend
functions are private additions; existing public exports remain available.
