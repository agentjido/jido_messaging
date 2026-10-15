# Messaging runtime limits: next checkpoints

Date: 2026-10-15.
Status: active goal. All checkpoints authorized on 2026-10-15.
Baseline: Messaging `1a544f9bbca469ea26be051ba2bf0398d371724d` (C5).

Continue after the completed [C1–C5 plan](2026-10-14-maintainability-checkpoints.md).
Run the checkpoints in the order below. Verify and record each checkpoint,
including each C8 subcheckpoint, then continue to the next checkpoint. The user
authorized completion of all checkpoints on 2026-10-15. This instruction replaces
the earlier requirement for a new instruction between checkpoints.

## Evidence and scope

The [ownership report](../runtime-ownership.md) identifies three recovery and
retention limits:

- Completed requests and unknown outcomes stay in ETS for the Runtime lifetime.
  Chat also keeps request history in each binding's resource table.
- AgentRunner and Demo.Bridge do not restore their subscriptions after Bus loss.
- A registry failure can stop many registered workers. The resulting restart
  burst can stop the instance and destroy Runtime state.

The [queue measurement](../outbound-queue-measurement.md) identifies a fourth
limit. With capacity two, 13 dispatch calls reached a busy partition's mailbox.
The rejected calls waited about 103–110 ms for a held provider. A 200 ms retry
wait also delayed a later call. These are controlled local test results.

Fix recovery before moving provider work to other processes. Then limit request
history in memory. Last, make queue admission responsive and bounded.

## Contracts to keep

Keep public function names, arguments, defaults, return shapes, process names,
public state structs, Signal schemas, and canonical stored-record formats.
Keep the 93 persistence callback signatures and the current adapter support
matrix. Do not add a required caller option, callback, external service, or
canonical database migration.

Keep these rules:

- Validate and authorize before returning a cached result. Revocation must still
  deny access to an earlier result.
- The same request, payload, and authority return the original completed result.
  A conflicting payload or authority returns the existing conflict error.
- An uncertain provider outcome must not release the request ID or cause an
  automatic repeat. Keep the existing in-progress and unknown-outcome errors.
- A caller timeout does not cancel accepted work. Do not add a provider deadline
  or cancellation rule in this plan.
- Keep receipt commit order, result publication, retry classification, routing,
  pressure policy, and dead-letter result fields.
- Keep resource owners, TTL, cancellation, and failure rules. Replaying a result
  does not renew a resource handle.
- Keep direct typed execution, ChatActions, Streaming, and Sender on their current
  paths. Gateway admission applies to gateway operations.

Internal ETS rows and supervisor child layout can change. They are not canonical
stored records. Compare public contracts separately from those internal details.

## Checkpoint order

| Checkpoint | Deliverable | Required result |
| --- | --- | --- |
| C6 | Restore library-owned Bus subscriptions | AgentRunner and Demo.Bridge receive new observations after Bus restart. |
| C7 | Isolate the instance registry and its workers | One registry failure does not restart Runtime or the Bus. |
| C8a–C8e | Isolate each remaining instance registry | Each dependency loss stays in its own process group. |
| C9 | Bound the Messaging request-history cache | Exact results remain available after memory-cache eviction. |
| C10 | Use the same retention policy for Runtime-created Chat bindings | The second request ledger no longer defeats the memory bound. |
| C11 | Split private Chat preparation, invocation, and completion | Public synchronous execution has the same results and resource rules. |
| C12 | Move gateway provider calls to monitored workers | Admission callbacks run during provider work and retry waits. |
| C13 | Reserve queue capacity before mailbox submission | Accepted dispatch work cannot exceed `queue_capacity`. |
| C14 | Run combined failure and load checks | Save the final compatibility, recovery, retention, and queue evidence. |

### Progress

| Checkpoint | Status | Evidence |
| --- | --- | --- |
| C6 | Complete | 2,278 tests passed, including PostgreSQL, integration, and story tests. Coverage: 11,531/12,803 lines (90.0648%). Public contract comparison: 19 modules unchanged. Format, compilation, and 16 Credo checks passed. CI: 22 passed, one expected skip on `19a79f66`. |
| C7 | Local verification complete; CI pending | 2,286 tests passed, including PostgreSQL, integration, and story tests. Coverage: 11,600/12,875 lines (90.0%). Public contract comparison: 22 modules unchanged. Format, compilation, and 16 Credo checks passed. |
| C8a | Local verification complete; CI pending | 2,292 tests passed. Coverage: 11,637/12,899 lines (90.2%). Public contracts: 24 modules unchanged. Format, compilation, and 16 Credo checks passed. |
| C8b | Local verification complete; CI pending | 2,297 tests passed. Coverage: 11,660/12,920 lines (90.2%). Public contracts: 25 modules unchanged. Format, compilation, and 16 Credo checks passed. |
| C8c | Local verification complete; CI pending | 2,303 tests passed. Coverage: 11,661/12,929 lines (90.1%). Public contracts: 27 modules unchanged. Format, compilation, and 16 Credo checks passed. |
| C8d | Local verification complete; CI pending | 2,307 tests passed. Coverage: 11,665/12,929 lines (90.2%). Public contracts: 29 modules unchanged. Format, compilation, and 16 Credo checks passed. |
| C8e | Pending | |
| C9–C14 | Pending | |

## C6 — Bus subscription recovery

Add one private subscription worker for each library-owned consumer. Use a
private supervisor. Monitor the consumer and the current Bus PID. Keep the
subscription ID, Bus generation, and retry timer in this worker.

Subscribe with the existing type and source/subject selectors. Use the Bus
`target:` option to send events to the existing consumer for its normal
validation and handling. The worker
must restore the subscription while an agent handler is busy. Keep handler
execution in AgentRunner.

Use one retry timer, with delay bounded between 100 ms and 1 second. Ignore
messages from old generations. Remove the subscription and timer when the
consumer stops. Keep the public `subscribed` field accurate when the consumer
can process its state updates.

Checks:

- Restart the Bus while the consumer is idle and while its handler is held.
- Repeat sequential Bus restarts. There must be one current subscription per
  consumer and one handler call per new matching observation.
- Stop the consumer during recovery. No subscription worker may remain.
- Keep Runtime alive and retain completed and unknown request entries.
- Confirm that selector and payload validation still reject unrelated events.

This restores future observations. It does not replay observations lost during
Bus downtime. Public callers of ordinary Bus subscriptions retain their current
subscription contract. Durable observation replay is separate work.

## C7 — Instance registry failure isolation

Add a private supervisor for the instance-registry dependency group. Place its
registry before a nested supervisor for SessionManager, OutboundGateway, and
InstanceSupervisor. Use `rest_for_one` in this small group. Keep Runtime, the
Bus, persistence, ConfigStore, Deduper, and DeadLetter outside it.

This groups dependent worker loss into one branch recovery. Do not raise the
top supervisor restart limit as the fix. Keep existing registered names and
lookup keys. During recovery, use the existing unavailable error forms.

Checks:

- Kill the registry with at least 64 gateway partitions running.
- Verify recovery of session partitions, gateway partitions, and configured
  provider instances. Wait for required dependencies before accepting work.
- Confirm unchanged Runtime and Bus PIDs and unchanged canonical ETS markers.
- Replay a completed request. Confirm that an unknown request stays unknown.
- Kill the registry after a provider effect and before its reply. A stable
  request ID must not cause a second provider effect.

Sender remains host-owned. Its host supervisor remains responsible for its
restart. Continuous failures can still exceed a branch restart limit; this
checkpoint isolates a single dependency failure and its resulting worker burst.

## C8 — Other registry groups

Use the C7 pattern only where the same dependency rule applies. Complete one
row at a time. Keep Runtime and the Bus outside all these groups.

| Stop point | Group | Recovery requirement |
| --- | --- | --- |
| C8a | Rooms registry and RoomSupervisor | Restore required room workers from canonical room state and retained desired start specifications. |
| C8b | Agents registry and AgentSupervisor | Restore assigned runners, including their handler configuration. Preserve room assignment recovery. |
| C8c | Bridges registry and BridgeSupervisor | Restore configured bridge workers from existing configuration. |
| C8d | Replay registry and replay workers | Restart the worker group together; retain DeadLetter state outside it. |
| C8e | Onboarding registry and supervisor | Recover the group only when the existing profile enables it. |

Keep desired dynamic child specifications outside the registry group that can
lose them. Store only the configuration needed to restore owned workers.
Remove a specification when its worker is explicitly stopped or unassigned.
Do not recover specifications from a registry that has already failed. Do not
serialize handler functions into canonical database records.

For each row, test registry loss, explicit stop, stale registration, and startup
failure. Check unique registration and the existing profile selection. Check
that unrelated groups, Runtime, the Bus, and request history survive. Test
room/agent recovery together after C8b. The scope is the instance registries;
global registries owned by other packages retain their upstream contracts.

## C9 — Messaging request retention

Bound retained request history in RAM without deleting its meaning. Use a
private SQLite request-history store and a bounded memory cache. Messaging
already depends on Exqlite. Keep this store separate from canonical persistence;
do not add adapter callbacks or change stored business records.

Use one store per Runtime lifetime. Retain key, exact authority, digest, owner,
status, and exact completed result. Write a claim before provider execution.
Write completion before treating it as recorded. Keep all request indexes on
disk. A full ID index or permanent tombstone map in ETS would retain the limit.

Initial private cache limits: 1,000 entries or 16 MiB of encoded entry data,
whichever occurs first. Bound database page-cache use separately. Read and
clean in batches of at most 100 entries. Do not load all IDs at startup.
These are internal limits, with no new required public option.

Preserve `RequestLedger` semantics. Keep resource entries out of request-history
cleanup. Store unknown outcomes without expiry. On a store read or write
failure, stop new provider execution through the affected ledger. Keep uncertain
claims and use existing contract error forms. Never fall back to an empty ledger.

The store owner must survive its worker's restart and keep the same Runtime
lifetime identifier. Reopen the same file after a store-worker failure. Runtime
shutdown ends this retention contract. A new Runtime must not silently reuse
the old file as a durable command log. Use private file permissions and remove
closed files. Do not log stored results, credentials, or private causes.

Checks:

- Retain 100,000 unique completed requests. Cache entries and encoded bytes
  must stay within both limits. Report ETS, BEAM, native database memory, and
  file size separately; do not claim the encoded-byte limit bounds all RAM.
- Replay the oldest result after eviction and store-worker restart. Compare
  the full returned term and provider call count.
- Test concurrent duplicate claims, authority changes, revocation, unknown
  owners, full disk, read/write failure, and shutdown during completion.
- Measure cache-hit, disk-hit, and new-claim latency before and after the change.

Disk use still grows with unique IDs. Exact replay for an unlimited Runtime
lifetime cannot have a fixed total storage bound. A disk quota with new rejection
rules, or expiry of old results, needs a separate contract decision. This plan
limits retained history in memory and handles storage failure without a resend.

## C10 — Runtime-created Chat binding history

Add a private request-store interface in Chat. Keep its public execution API
synchronous. Its default backend retains the current standalone ETS behavior.
Messaging supplies the C9 backend for bindings it creates and owns.

Install the backend before publishing a new binding. All Chat calls using that
binding must use the same claim authority. Keep a separate namespace for each
binding generation and for the outer Messaging ledger. Keep the existing
operation digest and conflict checks. Do not forward private store settings
to provider callbacks.

Keep resource values and their owner checks in the existing resource table.
Store request results and indexes in the request-history store. Include Chat's
per-result failure class and reason tag; these must not leave a second growing
ETS index. Preserve failure classification when an old result is read from disk.
A replayed resource reference keeps its original owner, expiry, and cancellation
state.

Checks cover old success and failure replay, concurrent calls through both Chat
and Messaging, binding replacement, resource expiry, cancellation, and failed
resources. Confirm there is no second unbounded in-memory request index.
Report resource-table use separately. A bound on request history does not bound
all resource values or all Runtime memory.

Externally created and registered bindings keep their external owner and
retention backend. Do not transfer ownership or replace the backend of a live
external binding. The memory bound covers Messaging-owned request history and
Runtime-created bindings. State this scope in the public ownership guide.

C10 and C11 require narrow companion changes in the Chat package. Keep the
Messaging dependency pinned to a verified Chat commit for CI. Deliver the Chat
changes before the Messaging changes that require them.

## C11 — Private prepare/invoke/complete boundary

Split the private Chat executor into preparation, provider invocation, and
completion. Keep `Jido.Chat.execute/2` as a synchronous wrapper over those steps.
Add the matching private boundary in ProviderCall for gateway use.

Preparation validates, claims the request, and resolves resource inputs in the
current resource-owner process. Provider invocation performs only the prepared
adapter operation and existing fallback sequence. Completion projects the result,
creates result resources in the original owner process, and records the result.
Do not move the entire executor into a short-lived task.

Use a private claim token for completion. Add an explicit unknown-outcome path
for a provider worker that dies after invocation starts. Coordinator survival
must not leave that request permanently marked as a live operation. A late or
duplicate completion must not complete another job.

Run the existing synchronous path first. Compare all native and fallback
operations, errors, cached results, resource owners, large results, streaming,
and existing load-options deadlines. No gateway scheduling change is included
in C11.

## C12 — Responsive gateway coordinator

Use the C11 boundary to run provider invocation in a supervised, monitored
worker. Keep preparation, resource ownership, queue state, retries, and
completion under the partition coordinator. Keep one active operation per
partition and the current FIFO order. Do not increase provider parallelism.

Replace retry sleeps and pressure throttle sleeps with timer-driven states.
A retry wait retains its job and capacity slot. Later jobs remain behind it.
Tag worker replies, DOWN messages, and timers with the current job generation.
Ignore stale messages. A partition failure must stop its provider workers;
do not leave an orphan worker active during partition recovery.

Preserve the accepted-work rule after caller timeout. Preserve existing retry
classification. A worker death with an uncertain effect produces the existing
unknown-outcome error and no automatic retry.

Use barriers to test blocked providers, retry waits, caller death, worker death,
partition death, stale replies, and shutdown before and after an effect. Check
resource ownership and exact result/receipt/publication order. Show that the
partition processes admission messages while the provider or retry is waiting.

## C13 — Admission before mailbox submission

Reserve a capacity slot before sending a dispatch call to the partition. Use
an atomic counter or compare-and-swap protocol in private shared state. Do not
put an unbounded admission-server mailbox in front of the existing mailbox.

One permit follows each job through reservation, preparation, queue, provider
work, retry wait, and completion. Enforce this per-partition invariant:

```text
reserved but not queued + queued + active or waiting for retry <= queue_capacity
```

If no permit exists, return the existing `queue_full` envelope without waiting
for the busy partition. Keep validation error precedence, pressure decisions,
dead-letter fields, and bridge status updates. Reuse pure error construction.
Measure the rejection path with DeadLetter and control-plane dependencies both
healthy and delayed. Do not hide a new wait in rejection recording.

Tie permits to a partition generation. Reclaim a caller's abandoned reservation
only if work was not accepted. Once accepted, caller timeout does not free its
slot or cancel the send. Release each permit once. On coordinator failure,
stop old workers before admitting a new generation. Keep uncertain request IDs
held even after their queue slot is released.

Required checks:

- Repeat the C5 workload. All overloaded calls must return before the held
  provider is released. A timed-out accepted call still follows the old rule.
- With capacity 64 and one held provider, run a burst of 10,000 calls. No more
  than 64 provider jobs may hold permits across mailbox, queue, and active work.
- Test reserve/submit races, caller death, partition and registry replacement,
  retries, queue drain, and duplicate/late replies. No permit may leak or be
  released twice.
- Record admission latency separately from provider completion latency. Accepted
  public calls still wait for their result.
- Run five local trials. For healthy dependencies, target p95 overload rejection
  below 50 ms and p99 below 100 ms. Save the machine, workload, and results.
  Use barrier-based correctness tests in CI. These local timing targets are
  measurement gates, not a production service guarantee.

The bound covers admitted gateway dispatch work. It does not bound all Erlang
control messages, arbitrary caller processes, or direct execution outside the
gateway. Document these limits explicitly.

## C14 — Combined checks and final evidence

Combine faults that cross the new boundaries: Bus loss during a held handler,
registry loss during a provider call, store failure after an external effect,
and caller timeout during queue recovery. Check stable-ID provider call counts,
request outcomes, Runtime survival, restored subscriptions, and permit cleanup.

Repeat the 100,000-request retention run and both queue workloads. Save raw
results and a short comparison with C5. Report remaining limits: disk growth,
external binding ownership, lost observations during Bus downtime, and direct
paths outside gateway admission. Do not claim durable exactly-once delivery.

## Completion checks and stop reports

For each checkpoint, save a baseline before edits. Add focused contract and
failure tests for that checkpoint. Compare public exports, defaults, structs,
Signal schemas, payload validation, and canonical record formats as applicable.
Test denial, duplicate IDs, and unknown outcomes at every changed boundary.

Run the complete affected package suite once the local change is ready. Messaging
checks include integration, story, and PostgreSQL tests. Keep production-source
coverage at or above 90%. Run format, compilation with warnings as errors, and
the existing static and package checks. Check CI on the delivered commit. Run
Chat checks when Chat changes. Do not lower coverage or broaden test exclusions.

Each stop report must state the changed files, commit, test and coverage results,
CI result or pending checks, measured behavior, and remaining limits. Keep one
focused delivery per checkpoint. Do not mix the next checkpoint into that
delivery. Do not change CHANGELOG or restore unrelated user deletions.

The active goal covers all checkpoints. Complete C6 first, record its results,
and continue through C14. Do not merge or publish packages.

### Open CI evidence

C7 and C8a remain open for final CI. The C7 run found a 100 ms caller-death
setup wait; commit `31a3b88` adds a one-second limit and caller cleanup. The C8a
run found two 100 ms recovery waits competing with the 100 ms retry timer; commit
`1d316d0` sets one-second test limits. Its focused regression run passed 18 tests.
That run also reported an intermittent existing concurrent endpoint-membership
lookup failure on OTP 29. The assertion now identifies the affected adapter.
Keep this issue open until a verified fix or clean repeated evidence resolves it.

C8b CI passed all test jobs, including PostgreSQL and the earlier recovery
regressions. Dialyzer found one unreachable private restoration clause. Commit
`394fc99` removes it; 25 focused agent tests passed. Final CI remains pending.
