# Story 00: Runtime Topology And SLOs

## Objective
Define the canonical runtime topology, failure-domain boundaries, restart policies, and measurable SLO baselines that all subsequent stories must implement against.

## Authoritative Scope
`ST-OCM-000` is the runtime architecture contract for this story set. Every runtime-facing story (`01` through `11`) inherits the topology, crash-policy, partitioning, and telemetry conventions in this file.

## Canonical Runtime Topology

### Supervisor Tree Shape
The canonical tree for one messaging module instance:

```text
JidoMessaging.Supervisor (root)
|- Registry.Rooms
|- Registry.Agents
|- Registry.Instances
|- Jido.Signal.Bus
|- RoomSupervisor (DynamicSupervisor)
|  `- RoomServer (1 process per room_id)
|- AgentSupervisor (DynamicSupervisor)
|  `- Agent workers (1 process set per agent_id)
|- InstanceSupervisor (DynamicSupervisor)
|  `- Instance subtree (1 subtree per instance_id)
|     |- InstanceServer
|     `- Channel runtime children (poller/sender/webhook listeners)
|- Deduper
`- Runtime
```

### Topology Matrix
Every subsystem must declare owner process, supervisor strategy, and restart intensity in `max_restarts/max_seconds` form.

| Subsystem | Owner Process | Supervisor | Strategy | Restart Intensity | Failure Domain Intent |
|---|---|---|---|---|---|
| Root runtime tree (`Registry.*`, signal bus, dynamic supervisors, `Deduper`, `Runtime`) | `JidoMessaging.Supervisor` | `JidoMessaging.Supervisor` | `:one_for_one` | `3/10s` | Keep global runtime alive; repeated root boot failures are fatal. |
| Room domain (`RoomServer`) | `RoomSupervisor` | `JidoMessaging.RoomSupervisor` | `:one_for_one` | `20/60s` | Room crashes are isolated per `room_id`. |
| Agent domain (agent workers/runners) | `AgentSupervisor` | `JidoMessaging.AgentSupervisor` | `:one_for_one` | `10/60s` | Agent failures are isolated per agent worker set. |
| Instance domain (`InstanceServer` + channel listeners) | `InstanceSupervisor` | `JidoMessaging.InstanceSupervisor` | `:one_for_one` | `6/30s` | Channel instance crashes are isolated per `instance_id`. |
| Per-instance subtree (`InstanceServer`, listener children) | Instance child supervisor (`JidoMessaging.Instance.<instance_id>`) | Child `Supervisor` started by `InstanceSupervisor` | `:one_for_one` | `5/30s` | Listener/poller failures restart locally before escalations. |
| Outbound gateway domain (Story 03+) | `OutboundGatewaySupervisor` | `JidoMessaging.OutboundGateway.Supervisor` | `:one_for_one` | `30/60s` | Partition workers can churn without cross-partition cascades. |
| Session routing domain (Story 06+) | `SessionManagerSupervisor` | `JidoMessaging.SessionManager.Supervisor` | `:one_for_one` | `15/60s` | Route-partition failures stay local to shard. |
| Operations domain (Story 09+, Story 11+) | `OnboardingSupervisor` / `ReplaySupervisor` | Feature-local supervisors under root | `:one_for_one` | `10/60s` | Control-plane and replay failures must not crash ingest/outbound hot path. |

### Escalation Rules
- Hitting restart intensity in any non-root domain escalates only that domain supervisor.
- Hitting restart intensity in the root runtime tree is `fatal` and must crash startup.
- New subtrees must default to `:one_for_one`; any alternative strategy requires explicit justification in story docs.

## Crash Policy Matrix
Failure handling uses exactly three classes: `fatal`, `recoverable`, `degraded`.

| Failure Mode | Class | Immediate Handling Guidance | Supervisor Action | Required Telemetry Dimensions |
|---|---|---|---|---|
| Runtime boot config invalid (missing required adapter/plugin/runtime config) | `fatal` | Fail fast during startup, return typed config error. | Stop subtree; propagate crash to root startup path. | `component`, `failure_class`, `reason`, `boot_stage` |
| Adapter initialization fails in `Runtime.init/1` | `fatal` | Do not retry in-process; require config/operator fix. | Runtime child exits; root restarts per intensity, then fails. | `component`, `failure_class`, `adapter`, `reason` |
| Channel listener transient disconnect or timeout | `recoverable` | Retry with bounded backoff and jitter; keep instance available where possible. | Restart failed child only (`:one_for_one`). | `component`, `failure_class`, `instance_id`, `attempt`, `elapsed_ms` |
| Outbound provider rate-limit / 5xx / timeout | `recoverable` | Retry with bounded attempts; preserve idempotency key and classify final disposition. | Restart worker if crashed; do not escalate cross-partition. | `component`, `failure_class`, `partition`, `attempt`, `provider_code` |
| Poison message / invalid payload in ingest or outbound serialization | `degraded` | Quarantine/drop item, emit dead-letter/audit event, continue queue. | Worker remains alive; no subtree restart required. | `component`, `failure_class`, `message_id`, `reason`, `disposition` |
| Policy/security module timeout with permissive fallback configured | `degraded` | Apply configured fallback (`deny` or `allow_with_flag`) and mark for review. | Keep pipeline running; no supervisor escalation. | `component`, `failure_class`, `policy_module`, `timeout_ms`, `fallback` |
| Repeated startup failures exceed domain restart intensity | `fatal` | Escalate to domain owner; require manual/operator intervention. | Domain supervisor terminates; root handles according to topology matrix. | `component`, `failure_class`, `restart_count`, `window_s`, `domain` |

### Classification Rules
- `fatal`: unrecoverable misconfiguration or repeated restart exhaustion; crash and surface immediately.
- `recoverable`: retry-safe transient failures; local restart and bounded retry expected.
- `degraded`: feature-level quality reduction while system remains operational; no process crash required.

## SLO Baselines And Pressure Thresholds
Baselines below are global defaults and must be measured via telemetry. Per-story SLOs may be stricter, never looser.

| Capability | SLI / Metric | Baseline Target | Pressure Thresholds | Telemetry Event | Required Dimensions |
|---|---|---|---|---|---|
| Ingest decision latency | p95 end-to-end ingest latency (`ingest_latency_ms`) | `<= 100ms` | warn `> 75ms`, critical `> 100ms` | `[:jido_messaging, :ingest, :completed]` | `instance_id`, `channel`, `outcome` |
| Outbound enqueue latency | p95 enqueue latency (`outbound_enqueue_ms`) | `<= 50ms` | warn `> 40ms`, critical `> 50ms` | `[:jido_messaging, :outbound, :enqueued]` | `instance_id`, `partition`, `operation` |
| Outbound delivery reliability | success ratio over 5m window (`delivery_success_ratio`) | `>= 99.5%` | warn `< 99.7%`, critical `< 99.5%` | `[:jido_messaging, :outbound, :result]` | `channel`, `provider_code`, `classification` |
| Instance reconnect recovery | p95 reconnect time after disconnect (`reconnect_mttr_ms`) | `<= 60_000ms` | warn `> 30_000ms`, critical `> 60_000ms` | `[:jido_messaging, :instance, :connected]` | `instance_id`, `attempts`, `reason` |
| Queue pressure safety | queue occupancy ratio (`queue_depth / queue_capacity`) | `< 0.70` steady-state | warn `>= 0.70`, degraded `>= 0.85`, shed `>= 0.95` | `[:jido_messaging, :pressure, :transition]` | `component`, `partition`, `pressure_level` |
| Crash containment | restart cascade count per incident (`cascade_count`) | `0` cross-domain cascades | critical `>= 1` | `[:jido_messaging, :supervisor, :escalation]` | `domain`, `source_child`, `restart_count` |

### Pressure Level Contract
- `normal`: below warn threshold.
- `warn`: emit pressure signals and scale visibility.
- `degraded`: activate throttles, lower-priority work deferral, and stricter timeouts.
- `shed`: reject or defer non-critical work to preserve core path.

## Partitioning And Sharding Guidance
Hot-path workers must be partitioned by stable keys and must not rely on singleton processes.

| Worker Domain | Unit Of Concurrency | Partition / Shard Key | Baseline Partitioning Rule | Notes |
|---|---|---|---|---|
| Room state (`RoomServer`) | one process per active room | `room_id` | Dynamic supervisor child per room. | Avoid cross-room mailbox contention. |
| Instance runtime (`InstanceServer` + channel listeners) | one subtree per channel instance | `instance_id` | Dynamic supervisor child subtree per instance. | Listener faults stay inside one instance subtree. |
| Ingest policy workers (Story 04+) | ingress policy worker partition | `hash(instance_id <> ":" <> room_id)` | `partition_count >= System.schedulers_online/0` with bounded per-partition queue length. | Preserve per-room ordering while scaling ingest across instances. |
| Outbound gateway partitions (Story 03+) | worker partition | `hash(instance_id <> ":" <> external_room_id)` | `partition_count >= 2 * System.schedulers_online/0` | Stable hashing preserves ordering per route key. |
| Session routing manager (Story 06+) | route-state shard | `hash(session_key)` | Same partition count family as outbound gateway. | Keep route updates and reads on same shard. |
| Onboarding state machine (Story 09+) | onboarding flow worker | `onboarding_id` | Dynamic child per active flow; optional shard pool for high cardinality. | Prevent long-lived flows from blocking unrelated onboarding. |
| Dead-letter replay workers (Story 11+) | replay partition | `hash(dead_letter_id)` | Replay partitions independent from live ingest/outbound workers. | Replay load must not starve live traffic. |

## Architecture Review Gate (Blocking)
Architecture review for any new subsystem is blocked unless all are explicit:

1. Owner process and supervisor name.
2. Supervisor strategy and restart intensity (`max_restarts/max_seconds`).
3. Crash policy class for each major failure mode (`fatal`/`recoverable`/`degraded`).
4. Partition/shard key and scaling rule for hot path.
5. SLO target and pressure thresholds.
6. Telemetry event names plus required dimensions.

If any item above is missing, the change is non-compliant with `ST-OCM-000` and must not merge.

## Cross-Story Reference Requirement
All subsequent stories (`01` through `11`) must explicitly reference Story 00 in their dependency section as:

`- Story 00: Runtime Topology And SLOs.`

## Completion Validation
Run all commands from repository root:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix precommit
```
