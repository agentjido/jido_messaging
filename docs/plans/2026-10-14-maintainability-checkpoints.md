# Messaging review checkpoints

Review baseline: `0e54ef8bd23473b3ee4df27ffb2916131e927622`.

Keep public function names, arguments, return values, Signal schemas, and stored
record formats stable. Do not combine all review changes in one checkpoint.

| Checkpoint | Review items | Work | Status |
| --- | --- | --- | --- |
| C1 | R1, R2 | Add PostgreSQL principal and authorization storage. Run all PostgreSQL tests in CI. Test a typed command with a real database. | Implemented; local tests passed |
| C2 | R3 | Reuse native Zoi schemas and operation metadata. Prove payload compatibility. | Pending |
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

The saved checkpoint report contains the final commit and CI results. Later
checkpoints remain pending.
