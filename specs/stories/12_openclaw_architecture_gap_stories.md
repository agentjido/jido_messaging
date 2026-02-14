# 12 — OpenClaw Architecture Gap Stories (Loop-Compatible)

Story cards for `scripts/ralph_wiggum_loop.sh`.

## Story Inventory

### ST-OCM-000 — Define runtime topology crash matrix and SLO baselines

#### Story ID
`ST-OCM-000`

#### Title
Define runtime topology crash matrix and SLO baselines

#### Persona
Messaging Platform Engineer (P1)

#### Priority
MVP Must

#### Primary Route/API
`Runtime supervisor topology and system-wide telemetry contracts`

#### Requirement Links
R1, R2, R3

#### Source Spec Links
specs/stories/00-runtime-topology-and-slos.md

#### Dependencies
none

#### Story
As a messaging platform engineer, I want an explicit topology and failure policy so every subsequent subsystem scales and follows OTP failure semantics.

#### Acceptance Criteria
1. Canonical runtime topology defines owner process, supervisor strategy, and restart intensity for each subsystem.
2. Crash policy matrix classifies failures as fatal/recoverable/degraded with handling guidance.
3. Baseline SLOs and pressure thresholds are defined and mapped to telemetry dimensions.
4. Partitioning/sharding guidance exists for all expected hot-path workers.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-000 happy path
  Given the runtime architecture docs are loaded
  When an engineer plans a new subsystem
  Then supervisor strategy restart intensity and crash policy are unambiguous

Scenario: ST-OCM-000 failure or edge path
  Given a proposed subsystem lacks crash policy details
  When architecture review is performed
  Then the change is blocked until topology and failure semantics are explicit
```

#### Evidence of Done
- Topology and crash matrix are documented and referenced by all subsequent stories.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-001 — Expand channel contract to v2 with optional lifecycle security and media hooks

#### Story ID
`ST-OCM-001`

#### Title
Expand channel contract to v2 with optional lifecycle security and media hooks

#### Persona
Channel Adapter Maintainer (P1)

#### Priority
MVP Must

#### Primary Route/API
`JidoMessaging.Channel` behavior contract

#### Requirement Links
R1, R4

#### Source Spec Links
specs/stories/01-channel-contract-v2.md

#### Dependencies
ST-OCM-000

#### Story
As a channel adapter maintainer, I want a richer optional contract so channels can express lifecycle, verification, sanitization, media, and command capabilities without breaking existing implementations.

#### Acceptance Criteria
1. New callbacks are optional and default behavior is deterministic.
2. First-party channel modules compile and existing behavior tests remain green.
3. Capability declarations align with callback support and are testable.
4. Callback failure classification is explicit for runtime crash/retry decisions.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-001 happy path
  Given a channel implements only v1 callbacks
  When it is loaded under the v2 behavior
  Then default v2 callbacks preserve compatibility

Scenario: ST-OCM-001 failure or edge path
  Given a channel advertises unsupported capabilities
  When contract checks run
  Then the inconsistency is surfaced as a typed failure
```

#### Evidence of Done
- Channel v2 behavior and defaults are documented and tested.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-002 — Implement instance lifecycle runtime with explicit supervisor semantics

#### Story ID
`ST-OCM-002`

#### Title
Implement instance lifecycle runtime with explicit supervisor semantics

#### Persona
OTP Runtime Engineer (P1)

#### Priority
MVP Must

#### Primary Route/API
`InstanceSupervisor` and `InstanceServer` lifecycle orchestration

#### Requirement Links
R2, R3, R5

#### Source Spec Links
specs/stories/02-instance-lifecycle-runtime.md

#### Dependencies
ST-OCM-000, ST-OCM-001

#### Story
As an OTP runtime engineer, I want deterministic lifecycle orchestration so instance startup reconnect and shutdown behavior is resilient and observable.

#### Acceptance Criteria
1. Instance startup resolves channel child specs and starts children deterministically.
2. Recoverable connection failures trigger bounded reconnect with telemetry.
3. Restart intensity and escalation behavior follow declared topology policy.
4. Worker crashes are isolated and do not cascade across unrelated subtrees.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-002 happy path
  Given a valid channel instance configuration
  When the instance starts
  Then expected children are supervised and health is reported

Scenario: ST-OCM-002 failure or edge path
  Given repeated startup failures occur
  When restart intensity limits are exceeded
  Then escalation behavior matches the crash policy matrix
```

#### Evidence of Done
- Lifecycle transition and crash-isolation tests are added.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-003 — Route outbound delivery through a partitioned gateway

#### Story ID
`ST-OCM-003`

#### Title
Route outbound delivery through a partitioned gateway

#### Persona
Messaging Delivery Engineer (P1)

#### Priority
MVP Must

#### Primary Route/API
`JidoMessaging.OutboundGateway` and `Deliver` integration

#### Requirement Links
R2, R3, R6

#### Source Spec Links
specs/stories/03-outbound-gateway.md

#### Dependencies
ST-OCM-000, ST-OCM-002

#### Story
As a messaging delivery engineer, I want one partitioned outbound path so retries idempotency chunking and rate policies are consistent and scalable.

#### Acceptance Criteria
1. `Deliver` sends and edits through gateway APIs only.
2. Outbound workers are partitioned by stable routing key and avoid singleton bottlenecks.
3. Queue bounds and pressure signals prevent unbounded growth.
4. Error categories are normalized for retry and terminal handling.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-003 happy path
  Given outbound messages for multiple rooms
  When delivery is executed
  Then work is distributed across partitions with consistent success metadata

Scenario: ST-OCM-003 failure or edge path
  Given a retryable provider error occurs
  When gateway processing runs
  Then retry behavior follows policy and records classification telemetry
```

#### Evidence of Done
- Gateway contract and partition behavior tests pass.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-004 — Enforce ingest policy pipeline with bounded gating and moderation

#### Story ID
`ST-OCM-004`

#### Title
Enforce ingest policy pipeline with bounded gating and moderation

#### Persona
Policy and Safety Engineer (P2)

#### Priority
MVP Must

#### Primary Route/API
`JidoMessaging.Ingest` policy execution path

#### Requirement Links
R2, R4, R7

#### Source Spec Links
specs/stories/04-ingest-policy-pipeline.md

#### Dependencies
ST-OCM-000, ST-OCM-001, ST-OCM-003

#### Story
As a policy and safety engineer, I want deterministic gating and moderation in the ingest hot path so deny/modify/flag outcomes are enforced before persistence and signaling.

#### Acceptance Criteria
1. Gating then moderation order is deterministic and configurable.
2. Denied messages are not persisted and do not trigger room/agent events.
3. Policy hooks are bounded by timeout budgets and cannot block ingest indefinitely.
4. Modified and flagged outcomes preserve metadata and emit policy telemetry.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-004 happy path
  Given gating and moderation modules are configured
  When an allowed message is ingested
  Then the message is persisted and downstream signals are emitted

Scenario: ST-OCM-004 failure or edge path
  Given a policy module times out
  When ingest evaluates policy
  Then timeout handling follows configured failure policy without hot-path deadlock
```

#### Evidence of Done
- Ingest policy coverage includes allow deny modify flag and timeout paths.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-005 — Add centralized security boundary for verify and sanitize

#### Story ID
`ST-OCM-005`

#### Title
Add centralized security boundary for verify and sanitize

#### Persona
Security Engineer (P2)

#### Priority
MVP Must

#### Primary Route/API
`JidoMessaging.Security` integration in ingest and outbound

#### Requirement Links
R4, R7, R8

#### Source Spec Links
specs/stories/05-security-boundary.md

#### Dependencies
ST-OCM-000, ST-OCM-001, ST-OCM-004

#### Story
As a security engineer, I want centralized verification and sanitization so spoofed senders and unsafe payloads are handled consistently across channels.

#### Acceptance Criteria
1. Inbound verification can deny untrusted sender identity claims.
2. Outbound sanitization applies deterministic per-channel formatting rules.
3. Security hook failures are classified and handled by explicit policy.
4. Security checks are bounded and observable by decision telemetry.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-005 happy path
  Given valid sender identity and outbound payload
  When message processing runs
  Then verification and sanitization complete successfully and delivery proceeds

Scenario: ST-OCM-005 failure or edge path
  Given sender verification fails
  When ingest processing runs
  Then message is denied with typed security reason and no persistence occurs
```

#### Evidence of Done
- Security contract and integration tests cover allow deny sanitize and timeout cases.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-006 — Introduce partitioned session routing manager

#### Story ID
`ST-OCM-006`

#### Title
Introduce partitioned session routing manager

#### Persona
Conversation Routing Engineer (P2)

#### Priority
MVP Should

#### Primary Route/API
`JidoMessaging.SessionManager` route state and resolution

#### Requirement Links
R3, R6, R9

#### Source Spec Links
specs/stories/06-session-routing-manager.md

#### Dependencies
ST-OCM-000, ST-OCM-003, ST-OCM-004

#### Story
As a conversation routing engineer, I want partitioned route state so outbound decisions remain deterministic and scalable across session traffic.

#### Acceptance Criteria
1. Route state operations are partitioned and avoid a single global process bottleneck.
2. TTL and eviction policies prevent unbounded route-state growth.
3. Outbound resolution uses route state with stale-route fallback logic.
4. Route manager crashes recover via supervision without global routing outage.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-006 happy path
  Given active sessions across threads and rooms
  When routing resolution is requested
  Then deterministic route selection uses fresh state and reports hit metrics

Scenario: ST-OCM-006 failure or edge path
  Given route state is stale or expired
  When outbound resolution executes
  Then fallback route logic selects a valid alternative and records fallback telemetry
```

#### Evidence of Done
- Session routing tests cover partitioning TTL fallback and crash recovery.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-007 — Implement first-class media ingest and outbound policies

#### Story ID
`ST-OCM-007`

#### Title
Implement first-class media ingest and outbound policies

#### Persona
Multimodal Platform Engineer (P2)

#### Priority
MVP Should

#### Primary Route/API
`Media normalization and outbound media gateway operations`

#### Requirement Links
R3, R6, R10

#### Source Spec Links
specs/stories/07-media-pipeline.md

#### Dependencies
ST-OCM-000, ST-OCM-001, ST-OCM-003, ST-OCM-006

#### Story
As a multimodal platform engineer, I want bounded media handling so ingest and delivery support image/audio/video/file payloads with deterministic fallback behavior.

#### Acceptance Criteria
1. Inbound channel payloads map to canonical media content blocks.
2. Outbound media operations route through gateway capability checks.
3. Type and size limits enforce bounded resource usage.
4. Unsupported media paths follow deterministic reject or fallback policy.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-007 happy path
  Given supported media content on a capable channel
  When media delivery runs
  Then payload dispatch succeeds and media metadata is persisted

Scenario: ST-OCM-007 failure or edge path
  Given unsupported media content for target channel
  When outbound dispatch runs
  Then deterministic fallback or reject behavior is applied and logged
```

#### Evidence of Done
- Media tests cover parse dispatch policy and fallback paths.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-008 — Normalize command and mention semantics across channels

#### Story ID
`ST-OCM-008`

#### Title
Normalize command and mention semantics across channels

#### Persona
Agent Interaction Engineer (P2)

#### Priority
MVP Should

#### Primary Route/API
`MsgContext command/mention normalization`

#### Requirement Links
R4, R7, R11

#### Source Spec Links
specs/stories/08-command-mention-normalization.md

#### Dependencies
ST-OCM-000, ST-OCM-001, ST-OCM-004, ST-OCM-007

#### Story
As an agent interaction engineer, I want deterministic command and mention metadata so policy and agent triggers behave consistently across channels.

#### Acceptance Criteria
1. Command parse outputs are deterministic for equivalent cross-channel inputs.
2. Mention metadata and `was_mentioned` semantics are normalized across adapters.
3. Require-mention and allowed-prefix policy controls are enforceable in ingest path.
4. Parsing uses bounded-cost evaluation to protect hot-path latency.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-008 happy path
  Given equivalent command messages from different channels
  When normalization runs
  Then parsed command and mention fields are equivalent

Scenario: ST-OCM-008 failure or edge path
  Given malformed or overlong command text
  When parser evaluation runs
  Then parsing fails safely with typed reason and bounded processing cost
```

#### Evidence of Done
- Normalization tests prove consistency and policy enforceability.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-009 — Add scalable directory lookup and onboarding state orchestration

#### Story ID
`ST-OCM-009`

#### Title
Add scalable directory lookup and onboarding state orchestration

#### Persona
Onboarding Systems Engineer (P3)

#### Priority
MVP Should

#### Primary Route/API
`Directory adapters and onboarding state machine APIs`

#### Requirement Links
R5, R9, R12

#### Source Spec Links
specs/stories/09-directory-onboarding.md

#### Dependencies
ST-OCM-000, ST-OCM-006, ST-OCM-008

#### Story
As an onboarding systems engineer, I want resumable onboarding and directory lookup abstractions so identity pairing and bootstrap flows are deterministic and auditable.

#### Acceptance Criteria
1. Directory lookup and search APIs expose consistent adapter contract behavior.
2. Onboarding transitions are validated deterministic and idempotent.
3. Flow state can be resumed after interruption.
4. Onboarding workers are supervised and crash isolation is preserved.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-009 happy path
  Given a valid onboarding request
  When onboarding transitions execute
  Then state advances deterministically and completion metadata is persisted

Scenario: ST-OCM-009 failure or edge path
  Given an interrupted onboarding flow
  When resume is requested
  Then flow resumes from persisted state without duplicate side effects
```

#### Evidence of Done
- Onboarding and directory tests cover transition guards, idempotency, and resume.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-010 — Load plugins from manifests with fail-fast required plugin policy

#### Story ID
`ST-OCM-010`

#### Title
Load plugins from manifests with fail-fast required plugin policy

#### Persona
Platform Integrations Engineer (P3)

#### Priority
MVP Should

#### Primary Route/API
`Plugin manifest loader and registry bootstrap`

#### Requirement Links
R1, R8, R12

#### Source Spec Links
specs/stories/10-plugin-manifest-discovery.md

#### Dependencies
ST-OCM-000, ST-OCM-001, ST-OCM-009

#### Story
As a platform integrations engineer, I want manifest-driven plugin loading so startup configuration is deterministic with clear fatal versus degraded failure behavior.

#### Acceptance Criteria
1. Valid manifests are parsed validated and registered deterministically.
2. Invalid required plugins fail startup fast with explicit diagnostics.
3. Invalid optional plugins degrade safely and emit warnings/telemetry.
4. Collision policy is deterministic and testable.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-010 happy path
  Given valid plugin manifests
  When startup bootstrap runs
  Then plugins are registered with deterministic precedence

Scenario: ST-OCM-010 failure or edge path
  Given a malformed required plugin manifest
  When startup bootstrap runs
  Then startup fails fast with typed diagnostics
```

#### Evidence of Done
- Plugin loader tests cover fatal and degraded startup branches.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.

### ST-OCM-011 — Add dead-letter replay and backpressure operational controls

#### Story ID
`ST-OCM-011`

#### Title
Add dead-letter replay and backpressure operational controls

#### Persona
Reliability and Incident Response Engineer (P3)

#### Priority
MVP Should

#### Primary Route/API
`Dead-letter APIs replay workers and pressure-policy controls`

#### Requirement Links
R2, R3, R6, R8, R13

#### Source Spec Links
specs/stories/11-resilience-ops.md

#### Dependencies
ST-OCM-000, ST-OCM-003, ST-OCM-005, ST-OCM-010

#### Story
As a reliability engineer, I want dead-letter replay and pressure controls so terminal failures are recoverable and queue growth remains bounded under stress.

#### Acceptance Criteria
1. Terminal failures are captured in dead-letter storage with diagnostic context.
2. Replay is idempotent and guarded against duplicate side effects.
3. Queue pressure thresholds trigger throttle/load-shed behavior before unbounded growth.
4. Replay and pressure worker crashes are isolated and recoverable under supervision.

#### Verification Scenarios
```gherkin
Scenario: ST-OCM-011 happy path
  Given dead-letter records exist
  When replay is executed
  Then recoverable records replay successfully with idempotent safety checks

Scenario: ST-OCM-011 failure or edge path
  Given sustained queue pressure exceeds thresholds
  When pressure policy executes
  Then throttling or shedding activates and emits operational telemetry
```

#### Evidence of Done
- Reliability tests cover dead-letter capture replay and pressure transitions.
- A matching traceability row exists in `specs/stories/00_traceability_matrix.md`.
