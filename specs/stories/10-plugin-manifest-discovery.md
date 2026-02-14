# Story 10: Plugin Manifest Discovery

## Objective
Add manifest-driven plugin discovery with clear startup failure policy that aligns with OTP fail-fast semantics.

## Problem / Gap
Plugins currently require manual registration. Missing manifest loading introduces operational drift and unclear startup behavior when plugin metadata is invalid.

## Dependencies
- Story 00: Runtime Topology And SLOs.
- Story 01: Channel Contract v2.
- Story 09: Directory & Onboarding.

## In Scope
- Define versioned plugin manifest schema.
- Implement manifest loader and registry bootstrap.
- Define strict startup policy for required plugins vs optional plugins.
- Add deterministic collision policy and diagnostics.
- Add telemetry for manifest load outcomes.

## Out of Scope
- Remote plugin marketplace.
- Runtime hot reloading of manifests.
- Artifact signing infrastructure.

## Public API / Interface / Type Changes
- Add manifest schema and loader API.
- Add startup config for manifest paths and required plugin set.
- Add failure policy type: `:fatal_required_plugin_error` vs `:degraded_optional_plugin_error`.
- Add diagnostics structure for schema and collision failures.

## Implementation Tasks
- Implement manifest parser/validator with version checks.
- Implement loader that maps entries to `Plugin` structs and registry registration.
- Implement startup bootstrap stage that enforces fatal/degraded policy.
- Implement collision handling and deterministic precedence.
- Add startup summary telemetry for plugin counts and failures.
- Document migration from manual registration to manifests.

## Acceptance Criteria
- Valid manifests load and register plugins deterministically.
- Invalid required plugin manifests fail startup fast and clearly.
- Invalid optional plugin manifests degrade gracefully with diagnostics.
- Collision behavior is deterministic and observable.
- Legacy manual registration remains compatible during transition period.

## Completion Validation
Run all commands from repository root:

```bash
mix compile --warnings-as-errors
mix test test/jido_messaging/plugin_test.exs
mix test test/jido_messaging/plugin_registry_test.exs
mix test
```

## Test Maintenance
- Unit tests:
- Add schema validation tests for manifest versioning and required fields.
- Add collision-policy tests and diagnostics formatting tests.
- Integration tests:
- Add startup tests for fatal-required and degraded-optional failure branches.
- Add regression tests for manual registration compatibility.

## Quality Gates
- `mix quality` must pass.
- `mix coveralls` must report coverage `>= 90%`.
- Plugin loader tests must be deterministic with static fixtures.

## Rollout / Observability
- Roll out with dual support for manual and manifest loading.
- Emit startup telemetry for required/optional failure counts.
- Provide operator checklist for manifest validation in CI.

## Risks / Mitigations
- Risk: Misclassified plugin criticality causes startup instability.
- Mitigation: explicit required-plugin list and startup policy tests.
- Risk: Silent degraded mode hides production impact.
- Mitigation: mandatory diagnostics emission and startup warning summaries.
- Risk: Manifest evolution breaks compatibility.
- Mitigation: versioned schema and compatibility tests.
