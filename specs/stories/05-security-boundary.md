# Story 05: Security Boundary

## Objective
Implement centralized inbound identity verification and outbound payload sanitization with OTP-aligned failure policies.

## Problem / Gap
Security behavior is fragmented by channel and not enforced through a single boundary. Spoofing and unsafe formatting concerns are inconsistently handled.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 01: Channel Contract v2.
- Story 04: Ingest Policy Pipeline.

## In Scope
- Add `Security` adapter interface for verify and sanitize operations.
- Enforce inbound verification before persistence.
- Enforce outbound sanitization before dispatch.
- Add timeout and fallback policy for security checks.
- Emit security decision telemetry.

## Out of Scope
- External key vault integration.
- Full business authorization matrix.
- Compliance reporting frameworks.

## Public API / Interface / Type Changes
- Add `JidoMessaging.Security` behavior with typed verify/sanitize results.
- Add runtime config for strict vs permissive enforcement and timeout budgets.
- Add security outcome metadata schema for ingest and outbound paths.

## Implementation Tasks
- Implement default security adapter with explicit permissive behavior.
- Integrate verify hook in handler/ingest boundary before message save.
- Integrate sanitize hook in outbound gateway before channel send/edit.
- Define security failure classes (deny, retry, degrade) and map to crash policy.
- Add structured telemetry for decisions and elapsed time.
- Document channel-specific sanitization invariants.

## Acceptance Criteria
- Inbound sender verification can deny untrusted traffic deterministically.
- Outbound payload sanitization is consistently applied before send.
- Security hook failures are classified and handled by configured policy.
- Security checks are bounded and do not block critical paths indefinitely.
- Existing channel behavior remains compatible under default permissive adapter.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/ingest_test.exs
mix test test/jido_messaging/deliver_test.exs
mix test test/jido_messaging/channels/telegram/handler_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add verify/sanitize contract tests including timeout and failure classification.
- Add tests for per-channel sanitization invariants.
- Integration tests:
- Add spoofed sender rejection flow tests.
- Add outbound unsafe payload sanitization and dispatch tests.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- No new dialyzer regressions from security types.

## Rollout / Observability
- Start with permissive mode by default, strict mode opt-in.
- Emit verification-deny and sanitization-adjustment metrics by channel.
- Publish operator guidance for toggling strict mode safely.

## Risks / Mitigations
- Risk: Strict verification causes false denials.
- Mitigation: staged rollout and explicit bypass policy per instance.
- Risk: Sanitization mutates intended content too aggressively.
- Mitigation: deterministic transforms and channel regression tests.
- Risk: Security failures create cascading outages.
- Mitigation: isolate checks with bounded execution and clear fallback policies.
