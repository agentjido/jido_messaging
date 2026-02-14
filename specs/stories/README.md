# OpenClaw Architecture Gap Stories

## Purpose
This folder defines a decision-complete implementation sequence for closing architecture gaps between `jido_messaging` and the OpenClaw channel messaging model.

Every story is structured to be implementation-ready and includes:
- scope and non-scope,
- public API/interface/type changes,
- implementation tasks,
- acceptance criteria,
- completion validation commands,
- test maintenance requirements,
- quality gates,
- rollout and risk controls.

## Execution Order
These stories are organized as a dependency graph, not strict waterfall.

### Foundation Lane
1. `00-runtime-topology-and-slos.md`
2. `01-channel-contract-v2.md`
3. `02-instance-lifecycle-runtime.md`

### Runtime/Data Plane Lane
4. `03-outbound-gateway.md`
5. `04-ingest-policy-pipeline.md`
6. `05-security-boundary.md`
7. `06-session-routing-manager.md`
8. `07-media-pipeline.md`
9. `08-command-mention-normalization.md`

### Control Plane/Operations Lane
10. `09-directory-onboarding.md`
11. `10-plugin-manifest-discovery.md`
12. `11-resilience-ops.md`

## Dependency Rule
A story can start when all dependencies listed in that story are complete. If dependencies are complete, stories may proceed in parallel.

## OTP Principles Used Across All Stories
- Prefer isolated processes with clear ownership boundaries.
- Let workers crash on unrecoverable local faults; recover through supervisors.
- Keep side effects at process edges, not in pure decision modules.
- Avoid singleton bottlenecks on hot paths; shard by stable keys.
- Use bounded mailboxes/queues and backpressure policies.
- Define restart strategy and restart intensity for every new subtree.

## Global Scalability/SLO Baselines
These baselines apply to every runtime-facing story unless superseded by stricter story criteria:
- Ingest p95 latency budget: <= 100ms under nominal load.
- Outbound enqueue p95 latency budget: <= 50ms under nominal load.
- No unbounded in-memory growth under sustained load.
- Queue-depth thresholds must trigger observable pressure signals.
- Recovery from single worker crash without supervisor cascade failure.

## Global Test and Quality Rules
Run these commands for every completed story:

```bash
mix test
mix quality
mix coveralls
```

Coverage must remain `>= 90%`.

## Definition Of Done
A story is complete when all are true:
- Acceptance criteria are satisfied.
- Completion validation commands pass locally.
- Unit and integration tests are added or updated.
- Existing tests remain green.
- `mix quality` passes with no regressions.
- Coverage remains `>= 90%`.
- Externally visible behavior changes are documented in changelog/release notes workflow.

## Scope And Assumptions
- Stories are documentation deliverables in this package.
- Story numbering is authoritative for dependency sequencing.
- No `bd` IDs are embedded in these files.
- Stories use markdown sections only (no YAML frontmatter).
- Repository quality policy remains unchanged.
