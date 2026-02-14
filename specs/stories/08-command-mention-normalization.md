# Story 08: Command & Mention Normalization

## Objective
Normalize command and mention semantics across channels with deterministic parsing and bounded-cost evaluation.

## Problem / Gap
Current mention/command behavior is fragmented by channel and adapter usage. Policy and agent logic cannot consistently rely on normalized fields.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 01: Channel Contract v2.
- Story 04: Ingest Policy Pipeline.
- Story 07: Media Pipeline.

## In Scope
- Standardize normalized command and mention fields in `MsgContext`.
- Integrate mention adapters into ingest enrichment path.
- Add deterministic command parser with clear failure reasons.
- Support policy controls for require-mention and allowed-prefix.
- Add parser performance limits for hot-path safety.

## Out of Scope
- Full command DSL ecosystems.
- Provider-side slash-command registration workflows.
- NLP intent parsing beyond prefix/mention semantics.

## Public API / Interface / Type Changes
- Extend `MsgContext` with command parse envelope and normalized mention metadata.
- Add parser settings for maximum parse length and prefix sets.
- Add policy option types for mention requirement and command prefix allowlists.

## Implementation Tasks
- Implement command parser utility with deterministic outputs.
- Integrate mention adapter execution into ingest context pipeline.
- Normalize command/mention metadata across first-party channels.
- Enforce parser bounds to avoid pathological-message cost spikes.
- Emit telemetry for parse success/failure and mention detection rates.
- Document normalized contract and migration guidance.

## Acceptance Criteria
- Equivalent command/mention inputs produce equivalent normalized context across channels.
- Require-mention and allowed-prefix policies are enforceable and deterministic.
- Parser execution is bounded and does not degrade ingest throughput.
- Existing channel handlers continue to pass after normalization changes.
- Parse failures include actionable reason metadata.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/adapters/mentions_test.exs
mix test test/jido_messaging/gating_test.exs
mix test test/jido_messaging/msg_context_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add parser tests for valid commands, invalid prefixes, and long-input bounds.
- Add mention normalization tests per first-party adapter.
- Integration tests:
- Add cross-channel ingest tests validating normalized command/mention fields.
- Add policy-enforcement scenarios for mention and prefix controls.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Handler and ingest tests must remain stable.

## Rollout / Observability
- Roll out as additive context contract changes.
- Emit parser latency and outcome metrics by channel.
- Provide migration notes for consumers using raw metadata fields.

## Risks / Mitigations
- Risk: Channel-specific mention formats create false positives/negatives.
- Mitigation: adapter fixture coverage and normalization invariants.
- Risk: Prefix parsing conflicts with natural conversation.
- Mitigation: explicit prefix policy with deterministic parser behavior.
- Risk: Parser complexity impacts latency.
- Mitigation: bounded parsing and performance telemetry.
