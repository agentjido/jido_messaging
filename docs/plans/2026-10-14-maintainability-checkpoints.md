# Messaging review checkpoints

Review baseline: `0e54ef8bd23473b3ee4df27ffb2916131e927622`.

Keep public function names, arguments, return values, Signal schemas, and stored
record formats stable. Do not combine all review changes in one checkpoint.

| Checkpoint | Review items | Work | Status |
| --- | --- | --- | --- |
| C1 | R1, R2 | Add PostgreSQL principal and authorization storage. Run all PostgreSQL tests in CI. Test a typed command with a real database. | Complete; local tests and CI passed |
| C2 | R3 | Reuse native Zoi schemas and operation metadata. Prove payload compatibility. | Complete; local tests and CI passed |
| C3 | R4, R5 | Extract entry-module workflows and ingest stages. Keep public forwarding functions and commit rules. | Complete; local tests and CI passed |
| C4 | R6 | Separate storage feature contracts and shared pure rules. Define stored-record compatibility. | Complete; local checks passed; final CI result in saved report |
| C5 | R7, R8 | Define process ownership, provider-call boundaries, and request retention. Measure queue behavior before concurrency changes. | Complete; local checks passed; final CI result in saved report |

## C1 scope and checks

Add the existing principal, membership, grant, and invocation-policy callbacks
to PostgreSQL. Preserve identity checks, exact revisions, terminal revocation,
namespace isolation, and record cleanup. Use database locks for concurrent
writes. Preserve principal access for participants stored before this change.

Check the required callback group without an unsupported-feature fallback.
Run shared principal and authorization tests on PostgreSQL. Test typed posting,
duplicate request IDs, denial after revocation, concurrent scope claims, and
concurrent revision updates. Run every PostgreSQL-tagged test and the normal
Messaging suite. Check format, compilation, public exports, and CI.

PostgreSQL optional feature groups remain explicit: external identity lifecycle,
credentials and assertion replay, agent endpoints and room assignment, agent
directory projections, delegation and continuity, trust evidence, and activity
projections. C1 does not claim support for these groups. C4 owns their contract
separation and further support decisions.

Stop after C1 and report its results. Do not begin C2 without a new instruction.

## C1 local result

PostgreSQL now implements all 13 callbacks in the principal and authorization
group. It implements 61 of the 93 persistence callbacks. The other 32 callbacks
belong to the optional groups above.

All 2,085 Messaging tests passed, including local integration, story, and
PostgreSQL tests. Production-source coverage is 90.0% (11,439 of 12,704 lines).
The expanded PostgreSQL selection passed all 82 selected tests. PostgreSQL 18.6
was used locally. CI uses PostgreSQL 17.

Migration 3 is required before runtime startup. It adds indexes and keeps stored
payloads unchanged. Public entry functions, record schemas, Signal schemas, and
the persistence behaviour signatures remain unchanged.

The saved C1 report contains the final commit and CI results. Commit `57a7608`
passed all 22 required CI checks; one experimental check was skipped.

## C2 scope and checks

Reuse native Zoi builders for IDs, resource references, senders, messages,
pages, and result envelopes. Keep the existing result-shape differences
explicit. Runtime posting permits only a `result` resource. Tool message
statuses use a smaller set than provider and runtime message statuses.
Runtime room and acknowledgement results have no resource alternative.

Use one operation table for request lookup, provider definitions, required
authorization actions, result shapes, and tool projections. Remove lookup
based on module names. Keep all 36 request mappings, 56 completed-result
variants, and three failure groups unchanged.

Compare all 65 compiled public Signal schemas and public function exports
with the C1 baseline. Replay the 8,192 saved positive and negative payload
cases. Keep fixed contract fixtures and add tests for nested fields, cursor
nullability, resource kinds, status sets, and failure-code boundaries.
Run the complete Messaging suite, PostgreSQL tests, coverage, format,
compilation, static checks, and CI.

Stop after C2 and report its results. C3–C5 require a new instruction.

## C2 local result

Shared native builders and one operation table replace repeated result schemas
and lookup by module name. Production source is smaller by 2,850 lines. The
schemas are built at compile time; payload validation uses the compiled schemas.

All 65 native schemas and their JSON Schema forms match the C1 baseline exactly.
The public function exports match. All 8,192 saved payload cases retain the same
acceptance decision and parsed output. Fixed fixtures cover the 36 request
mappings and all 56 completed-result variants.

All 2,214 Messaging tests passed, including local integration, story, and
PostgreSQL tests. The 129 new contract tests cover schema fingerprints, payloads,
operation mappings, and nested validation rules. Production-source coverage is
90.1% (11,495 of 12,749 lines). Both new internal modules have 100% line coverage.
Format, compilation with warnings treated as errors, and 16 Credo checks passed.

The saved C2 checkpoint report contains the final commit and CI results.
Commit `1770bc3` passed 22 CI checks; one experimental compile check was skipped.

## C3 scope and checks

Move assignment and recovery, room setup, and transcript workflows into
internal modules. Keep public functions as forwarding functions with their
existing guards and default arguments. Keep the instance macro unchanged.
Document the application, record, and operator entry paths.

Extract ingest policy and thread workflows. Use plain preparation, policy,
commit, and publication stages with typed transient data. Keep the original
write, read-back, duplicate-claim, rollback, and observation rules.

Compare moved function bodies with the baseline. Compare compiled public
function and macro exports. Run stage-order tests on both the original code
and the extracted code. Check policy denial, failures after writes, uncertain
store outcomes, automatic thread work, assignment recovery, room setup, and
history scope. Run the complete Messaging suite, PostgreSQL tests, coverage,
format, compilation, static checks, and CI.

See [Workflow boundaries](../workflow-boundaries.md) for ownership and commit
rules. Stop after C3 and report its results. C4 and C5 remain pending.

## C3 local result

Fourteen public functions now forward to assignment, room setup, and transcript
owners. The entry module is 2,308 lines, down from 3,281. Ingest is 821 lines,
down from 1,470. Policy and thread work are separate internal modules. The
coordinator has explicit preparation, policy, commit, and publication stages.

All 193 copied function clauses match the baseline after internal export and
name changes. The 14 forwarding function heads, guards, and defaults match.
The instance macro, canonical commit function, observation handler, and
duplicate-claim finalization functions match. Compiled public function and
macro exports are unchanged. Stored record and public Signal schemas are
unchanged.

The stage-order tests passed before and after extraction. All 237 focused tests
and all 2,220 Messaging tests passed. The full suite includes local integration,
story, and PostgreSQL tests. Production-source coverage is 90.0% (11,512 of
12,781 lines). Format, compilation with warnings treated as errors, and 16
Credo checks passed.

The saved C3 report contains the final commit and CI results. C4 and C5 remain
pending.

## C4 scope and checks

Define small storage feature behaviours. Keep all 93 aggregate callback
signatures and optional callbacks for existing custom adapters. Require every
callback in each declared feature. Preserve the existing support matrix:
ETS has 91 callbacks, SQLite has 93, and PostgreSQL has 61. ETS does not add
transactions or connection release. PostgreSQL does not add optional features.

Extract only pure rules: immutable identity, revision transitions, terminal
revocation, directory and activity revisions, cursor options, index values,
and the existing payload codec. Keep SQL, scoped reads, writes, locks,
transactions, cleanup, and connection ownership in each adapter.

Define the current unwrapped Erlang record format as v1. Save pre-C4 record
fixtures before edits. Test old record fields and values, database reopen,
unchanged stored bytes on reads, message order, and ID cursors. Define the
contract for a future version change without changing the current write format.

Compare public exports, aggregate callback signatures, and SQL. Run shared
storage contracts, the complete Messaging suite, PostgreSQL tests, coverage,
format, compilation with warnings treated as errors, static checks, and CI.

See [Storage feature contracts](../storage-contracts.md) and
[Stored-record compatibility](../stored-record-compatibility.md).
Stop after C4 and report its results. Do not begin C5 without a new instruction.

## C4 local result

Thirteen feature behaviours now define complete storage groups. The built-in
adapters declare the groups they support. Fixed tests require an exact
partition of the aggregate behaviour and the existing support matrix.
The reusable conformance suite also checks every declared feature.

Shared pure rules replace repeated authorization, credential, directory, and
activity logic. The payload codec retains the existing Erlang encoder and
each adapter's decoder options. No record shape, database migration, SQL
statement, runtime capability, dependency, or package version changes.

All public exports match for 12 checked modules. All 93 aggregate callback
signatures and optional callbacks match the baseline. The source comparison
confirms 662 unchanged adapter function clauses after shared helper call
changes are accounted for. Every SQL statement matches.

Fixed samples cover 23 stored struct shapes. Eight core samples use public
constructors and are read from reopened SQLite and PostgreSQL stores. Reads
preserve the stored payload bytes. A write and read cycle preserves record
values; Erlang map entry order is not a byte equality guarantee across VMs.

All 251 focused storage tests and all 2,253 Messaging tests passed. The full
suite includes local integration, story, and PostgreSQL tests. Production-source
coverage is 90.0% (11,449 of 12,708 lines; the unrounded ratio is above 90%).
The new pure rule module covers 66 of 67 lines. The contract registry and payload
codec have full line coverage. Format, compilation, and 16 Credo checks passed.

The saved C4 report contains the final commit and CI results. C5 remains pending.

## C5 scope and checks

Extract common provider-call mechanics. Keep each caller's authorization,
sanitization, queue, retry, receipt, and publication rules. Preserve legacy
Streaming and Sender callback arities and return values. Add safe internal
diagnostics without private payloads or causes.

Extract the request admission protocol into a small ledger. Keep the existing
entry format, principal/payload/authority checks, completed-result cache,
and unknown-owner rule. Retain IDs for Runtime lifetime. Do not introduce
expiry that can repeat an external effect.

Define process groups, resource owners, dependency loss, and restart limits.
Keep existing profiles and supervisor strategies. Test Runtime and Bus restart,
registry loss, and partition death after an effect. Measure the partition
mailbox, overload rejection, caller timeout, and retry-wait delay before any
concurrency change. No concurrency change is included in C5.

Compare compiled exports, state schemas and structs, and moved function bodies.
Run the full suite with PostgreSQL, coverage, format, compilation, static checks,
and CI. See [Runtime ownership](../runtime-ownership.md) and
[Queue measurement](../outbound-queue-measurement.md).
Stop after C5 and report the results.

## C5 local result

Shared provider-call code now has one internal owner. Existing callers keep
their authorization, sanitization, retry, queue, receipt, and publication rules.
Streaming and Sender keep their legacy callback contracts. Safe diagnostics
record stage, operation, outcome, class, and public correlation.

The request ledger retains the existing entry format and Runtime lifetime.
Completed successes and failures remain cached. Dead-owner requests remain
unknown and cannot be reclaimed automatically. No age or size eviction is added.
The ownership document defines resource owners, profiles, and restart limits.

The queue probe found 13 pending calls with internal capacity two. Overload
rejection waited for the held provider. A caller timeout did not cancel a send.
A later call also waited for a 200 ms retry backoff. No concurrency or supervisor
strategy change is included. Bus subscriptions are lost on Bus restart; registry
failure can cause an instance restart and reset volatile state. These existing
limits are explicit and have failure tests.

Exports, structs, defaults, callbacks, and native field schemas match for 19
checked modules. Field-key order is sorted for map-defined native schemas.
Seven copied provider clauses and 258 existing function clauses match after
helper-call and diagnostic changes. Public Signal and stored record contracts
remain unchanged.

All 2,268 Messaging tests passed, including integration, story, and PostgreSQL
tests. The 15 new tests cover retention, ownership, provider boundaries, and
dependency loss. Production-source coverage is 90.0% (11,469 of 12,740 lines;
the unrounded ratio is 90.02%). All three new internal modules have full line
coverage. Format, compilation, and 16 static checks passed.

The saved C5 report contains the final commit and CI results. Stop after C5.
Further admission, bounded retention, and recovery changes are separate work.
