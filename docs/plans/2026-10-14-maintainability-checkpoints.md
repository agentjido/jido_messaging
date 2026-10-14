# Messaging review checkpoints

Review baseline: `0e54ef8bd23473b3ee4df27ffb2916131e927622`.

Keep public function names, arguments, return values, Signal schemas, and stored
record formats stable. Do not combine all review changes in one checkpoint.

| Checkpoint | Review items | Work | Status |
| --- | --- | --- | --- |
| C1 | R1, R2 | Add PostgreSQL principal and authorization storage. Run all PostgreSQL tests in CI. Test a typed command with a real database. | Complete; local tests and CI passed |
| C2 | R3 | Reuse native Zoi schemas and operation metadata. Prove payload compatibility. | Implemented; local tests passed |
| C3 | R4, R5 | Extract entry-module workflows and ingest stages. Keep public forwarding functions and commit rules. | Pending |
| C4 | R6 | Separate storage feature contracts and shared pure rules. Define stored-record compatibility. | Pending |
| C5 | R7, R8 | Define process ownership, provider-call boundaries, and request retention. Measure queue behavior before concurrency changes. | Pending |

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
C3–C5 remain pending.
