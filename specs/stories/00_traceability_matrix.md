# 00 — Story Traceability Matrix

This matrix maps loop-compatible OpenClaw architecture stories to route/API scope, requirements, and source specs.

| Story ID | Domain File | Primary Route/API | Requirements | Source Specs |
|---|---|---|---|---|
| `ST-OCM-000` | `12_openclaw_architecture_gap_stories.md` | `Runtime topology and telemetry contracts` | R1,R2,R3 | specs/stories/00-runtime-topology-and-slos.md |
| `ST-OCM-001` | `12_openclaw_architecture_gap_stories.md` | `JidoMessaging.Channel behavior contract` | R1,R4 | specs/stories/01-channel-contract-v2.md |
| `ST-OCM-002` | `12_openclaw_architecture_gap_stories.md` | `InstanceSupervisor/InstanceServer lifecycle` | R2,R3,R5 | specs/stories/02-instance-lifecycle-runtime.md |
| `ST-OCM-003` | `12_openclaw_architecture_gap_stories.md` | `JidoMessaging.OutboundGateway + Deliver` | R2,R3,R6 | specs/stories/03-outbound-gateway.md |
| `ST-OCM-004` | `12_openclaw_architecture_gap_stories.md` | `JidoMessaging.Ingest policy path` | R2,R4,R7 | specs/stories/04-ingest-policy-pipeline.md |
| `ST-OCM-005` | `12_openclaw_architecture_gap_stories.md` | `JidoMessaging.Security verify/sanitize` | R4,R7,R8 | specs/stories/05-security-boundary.md |
| `ST-OCM-006` | `12_openclaw_architecture_gap_stories.md` | `JidoMessaging.SessionManager` | R3,R6,R9 | specs/stories/06-session-routing-manager.md |
| `ST-OCM-007` | `12_openclaw_architecture_gap_stories.md` | `Media normalization and outbound media ops` | R3,R6,R10 | specs/stories/07-media-pipeline.md |
| `ST-OCM-008` | `12_openclaw_architecture_gap_stories.md` | `MsgContext command/mention normalization` | R4,R7,R11 | specs/stories/08-command-mention-normalization.md |
| `ST-OCM-009` | `12_openclaw_architecture_gap_stories.md` | `Directory adapters + onboarding state machine` | R5,R9,R12 | specs/stories/09-directory-onboarding.md |
| `ST-OCM-010` | `12_openclaw_architecture_gap_stories.md` | `Plugin manifest loader bootstrap` | R1,R8,R12 | specs/stories/10-plugin-manifest-discovery.md |
| `ST-OCM-011` | `12_openclaw_architecture_gap_stories.md` | `Dead-letter replay + pressure policy` | R2,R3,R6,R8,R13 | specs/stories/11-resilience-ops.md |
