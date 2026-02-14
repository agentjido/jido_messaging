# Story 01: Channel Contract v2

## Objective
Expand the channel contract to support routing metadata, lifecycle hooks, security hooks, media primitives, and command semantics while preserving backward compatibility.

## Problem / Gap
`JidoMessaging.Channel` currently models normalize/send only. It does not provide first-class contracts for lifecycle child specs, sender verification, output sanitization, command extraction, or media operations.

## Dependencies
- Story 00: Runtime Topology And SLOs.

## In Scope
- Define Channel Contract v2 optional callbacks and result envelopes.
- Preserve v1 compatibility with deterministic defaults.
- Align first-party channels with v2 contract and capability model.
- Add guidance for adapter authors on OTP-safe callback behavior.

## Out of Scope
- Runtime lifecycle orchestration.
- Full outbound gateway implementation.
- Policy engine enforcement.

## Public API / Interface / Type Changes
- Extend `JidoMessaging.Channel` with optional callbacks for:
- listener child-spec declaration,
- routing metadata extraction,
- sender verification hook,
- outbound sanitization hook,
- media send/edit hooks,
- command hint extraction.
- Add new channel capability atoms for these primitives.
- Define callback timeout and failure result conventions so runtime can decide crash/retry/degrade consistently.

## Implementation Tasks
- Define callback contracts and typed result envelopes.
- Implement default callback helpers with deterministic safe behavior.
- Update first-party channels to explicitly declare supported v2 capabilities.
- Add compile-time checks ensuring channel modules advertise capability/callback consistency.
- Add docs describing callback failure semantics and OTP expectations.

## Acceptance Criteria
- Existing Telegram/Discord/Slack/WhatsApp channels compile and pass tests with no functional regressions.
- New callbacks are optional and defaults are deterministic.
- Capability negotiation reflects new primitives accurately.
- Channel callback failures map to explicit recoverable/non-recoverable categories.
- Documentation includes callback timeout guidance and crash-boundary expectations.

## Completion Validation
Run all commands from repository root:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/jido_messaging/channel_test.exs
mix test test/jido_messaging/channels/telegram_test.exs
mix test test/jido_messaging/channels/discord_test.exs
mix test test/jido_messaging/channels/slack_test.exs
mix test test/jido_messaging/channels/whatsapp_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add v2 contract tests for callback defaults, timeout handling, and capability declarations.
- Add tests for callback failure classification behavior.
- Integration tests:
- Validate legacy v1-only custom channel module behavior remains functional.
- Validate first-party handlers still process text path and emit expected signals.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- No new credo or dialyzer regressions.

## Rollout / Observability
- Roll out as non-breaking contract expansion.
- Emit telemetry when defaults are used for missing callbacks to track migration progress.
- Add changelog entries for callback and capability additions.

## Risks / Mitigations
- Risk: Capability declarations diverge from callback behavior.
- Mitigation: compile-time checks and contract tests.
- Risk: Callback timeouts block hot paths.
- Mitigation: explicit timeout budgets and classification of timeout as recoverable or fatal.
- Risk: Hidden behavior drift from defaults.
- Mitigation: telemetry on default usage and strict behavior tests.
