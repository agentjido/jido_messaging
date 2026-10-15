# Runtime ownership and failure limits

This document defines the runtime contract after C6. Public functions, existing
process names, state structs, Signal schemas, and stored records remain unchanged.
C6 adds private subscription workers. Request retention, provider scheduling,
and the existing supervisor strategies remain as measured in C5.

## Process groups

The instance supervisor uses `one_for_one`. Its default restart limit is the
OTP default: three restarts in five seconds. Each dynamic supervisor has its
own limit. A child failure can therefore cause a parent restart when many
dependent workers fail together.

The current `:core` profile starts all 17 base children. The `:full` profile
also starts the onboarding registry and supervisor. An explicit `:onboarding`
feature also enables those two children. Unknown profile values retain the
existing full-profile behavior. `:core` is not a minimal store-only profile.

| Responsibility | Processes | Requirement |
| --- | --- | --- |
| Canonical state and typed commands | Runtime, RoomSupervisor, RoomServer, room registry | Required for room workflows and direct execution |
| Observations | Instance Signal Bus; private subscription supervisor and workers | Required for publication; does not execute commands |
| Agent integration | AgentSupervisor, AgentRunner, agent registry | Required for assigned handlers; starts in both existing profiles |
| Delivery and routing | SessionManager supervisor/partitions, OutboundGateway supervisor/partitions, DeadLetter, replay supervisor/workers | Required by existing delivery paths; starts in both profiles |
| Provider connections | InstanceSupervisor and InstanceServer; BridgeSupervisor and BridgeServer | Required by connection/configuration paths; starts in both profiles |
| Control plane | ConfigStore, Deduper, instance and bridge registries | Required by the preceding groups; starts in both profiles |
| Onboarding | Onboarding registry/supervisor and task workers | Optional; selected as above |
| Demo and Jidoka integration | Demo modules, host handlers, endpoint/identity services | Not started as separate children by the instance supervisor |

These are responsibility groups, not new supervisor branches. A future minimal
profile must select complete dependency groups. It must keep existing profiles
compatible. A package split must first define the host boundary for Demo and
Jidoka integration; C5 does not split packages.

## Resource owners

| Resource | Owner | Lifetime and dependency |
| --- | --- | --- |
| Persistence state | Runtime | Adapter `init/1` runs in Runtime; normal termination calls `close/1` |
| ETS record and index tables | Runtime | Tables disappear when Runtime exits; no durable recovery |
| SQLite handle | Runtime adapter state | Normal close releases it; SQLite file records survive restart |
| Owned PostgreSQL pool | Runtime through the adapter | Pool is linked to its creator; adapter closes an owned pool |
| Host PostgreSQL pool | Host application | Adapter does not close a supplied pool |
| Catalog, binding map | Runtime | Rebuilt on Runtime restart |
| Typed request ledger and instance resource handles | Runtime, one public ETS table | Direct callers write claims; only Runtime owns table lifetime |
| Runtime-created Chat binding resource table | Runtime | `ensure_binding/4` creates the binding in Runtime |
| Externally registered Chat binding resource table | Binding creator | Registration does not transfer ETS ownership; creator must outlive calls |
| Bus records and subscription definitions | Instance Bus memory store | Lost on Bus restart; ordinary targets must subscribe again |
| Agent subscription and handled-message window | AgentRunner / Bus | Runner subscribes at startup; window retains at most 1,000 IDs |
| Room cache and timers | RoomServer | Room state is read from persistence; room restart restores supervisor-owned agent assignments |
| Session route table and prune timer | SessionManager partition | Private ETS and timer end with partition |
| Outbound queue, reply handles, success cache | OutboundGateway partition | Volatile; provider call and retry wait run in the same process |
| Dead-letter records and order | DeadLetter | Volatile; default limit is 5,000 records |
| Replay work and registry | Replay workers and their registry under replay supervisor | Depends on replay registry and DeadLetter |
| Inbound dedupe table and sweep timer | Deduper | Private ETS; default normal TTL is one hour, sweep is one minute |
| Connection listeners and reconnect timers | InstanceServer subtree / reconnect worker | Depends on instance registry and resolved provider configuration |
| Bridge state | BridgeServer under BridgeSupervisor | Depends on bridge registry and ConfigStore/Runtime |
| Streaming pending content and flush timer | Streaming process | Started with `GenServer.start`; caller controls finish/cancel; not an instance child |
| Legacy send queue and retry timers | Sender process | Host starts this optional worker; not an instance child |
| Global bridge manifest table | First caller, with `:init` as ETS heir | VM-local shared registry; instance startup does not give it isolated ownership |
| Moderator rate-limit table | First caller, with `:init` as ETS heir | VM-local; records are cleaned when the sender window is checked |

Resource-handle expiry is separate from request retention. Chat handles have
their own TTL and cancellation rules. The request ledger must not sweep handle
entries or interpret a handle as a request claim.

## Provider-call boundaries

`ProviderCall` owns common binding selection, option normalization, typed Chat
execution, result aliases, and failure projection. `AdapterBridge` retains its
existing exports and forwards operation calls. Runtime retains binding creation,
credential resolution, configuration revisions, and binding ownership.

| Caller | Rules retained by caller | Queue and retry |
| --- | --- | --- |
| Direct typed `Execution` | Validate request; authorize trusted scope before admission; external-ID mapping; limits; receipt preparation/commit; result publication | Runs in caller; no gateway admission or automatic retry |
| Deliver / OutboundRouter through OutboundGateway | Routing; ingress or agent authority; sanitize output; media policy; dead-letter capture | Serialized per partition; existing classified retries |
| ChatActions through AdapterBridge | Tool policy, actor/scope checks, payload conversion | Runs in caller; no implicit gateway queue or retry |
| Streaming legacy channel callbacks | Host-selected channel and options; edit throttle; finish/cancel | Runs in Streaming process; no typed binding, gateway admission, or automatic retry |
| Sender legacy channel callback | Host-selected channel and legacy delivery job | Host-owned queue and timer retries; no typed binding or gateway policy |

The common boundary does not grant authority. It does not publish requests to
the Bus. It does not add gateway policy to direct calls. Streaming keeps its
legacy `send_message/3` and `edit_message/3` callbacks and raw return values.
Sender keeps its legacy `send_message/3` callback and its existing empty options.

Safe internal diagnostics expose stage, operation, outcome, failure class,
Signal ID, and request ID. Provider duration uses native monotonic time units
and includes typed validation and cached lookups. It is not a network latency
metric. Diagnostics omit payloads, credentials, private causes, and stack traces.
Public error codes and retry flags remain unchanged.

## Request retention

`RequestLedger` is a small ETS protocol, not a new process. A typed admission
key is `{principal_id, request_id}`. The digest covers request type and payload.
The stored authority includes grant and policy revisions, constraints, and any
route decision. Validation and authorization happen before cached results are
read. Revocation cannot expose an earlier cached success.

| Entry | Same payload and authority | Different payload or authority | Retention |
| --- | --- | --- | --- |
| Running, owner alive | `request_in_progress` | `request_conflict` | Runtime lifetime |
| Running, owner dead | `request_outcome_unknown` | `request_conflict` | Runtime lifetime; never reclaimed automatically |
| Completed success or failure | Original result | `request_conflict` | Runtime lifetime; no age or size eviction |

The existing four-element ETS entry format is unchanged. No request ID expires
while Runtime owns the table. A process restart that destroys Runtime also
destroys these entries. This is local deduplication, not a durable exactly-once
guarantee. Reconcile an uncertain external effect before restarting an owner or
submitting a new ID. C5 adds no reconciliation API or automatic unknown retry.

Chat also retains its own per-binding request entries. A gateway success cache
is a separate bounded FIFO; its default limit is 1,000. Cache eviction does not
release a stable Chat request ID. Callers that omit a stable request ID do not
get that protection after the gateway cache is lost. Inbound Deduper has another
protocol: ordinary entries expire; explicitly unknown entries stay pinned until
clear or owner shutdown.

Memory therefore grows with unique typed requests during a long Runtime life.
A bounded completed-result window would need permanent or durable ID
tombstones, an explicit expired-ID response, and result-resource cleanup rules.
Evicting entries and accepting old IDs as new could repeat external effects.
That policy is outside C5 because it changes current public return behavior.

## Verified restart limits

Tests stop and restart Runtime and the Bus, kill the instance registry, and
kill a partition after a provider effect but before its reply.

* Runtime restart removes its ledger, binding map, created-binding resources,
  and ETS records. External binding tables survive if their owner survives,
  but their registration must be restored.
* Bus restart leaves Runtime alive but removes ordinary subscriptions. Public
  subscribers must subscribe again. AgentRunner and Demo.Bridge each have a
  private worker that monitors the Bus and restores their subscription. The
  worker can restore it while the consumer's handler is busy. Missed
  observations are not replayed by the current memory store.
* Registry loss restarts registered delivery workers. A large simultaneous
  restart burst can exceed supervisor limits and restart the whole instance.
  Recovery can therefore reset Runtime and its volatile state. It does not
  guarantee preservation of requests or ETS records.
* A partition restart preserves a Runtime-owned Chat binding. A request whose
  provider owner died after an effect remains `request_outcome_unknown` and
  terminates at attempt one. It does not cause a second provider call.

These tests define existing failure limits. They do not claim continuous
delivery across dependency loss. Before a later restart-policy change, group
the instance registry with its registered workers and test isolated recovery.
Do not replace the entire instance strategy with `rest_for_one` without those
contracts.

## Managed subscriptions after C6

Each library consumer owns one subscription worker. The worker monitors its
consumer and the current Bus PID. It retries with one timer and a delay between
100 ms and one second. Old retry tokens and Bus monitor messages are ignored.
The private registry prevents duplicate workers for the same consumer PID.

The worker uses the existing type and source/subject selectors. The Bus sends
observations directly to the consumer through its `target:` option. Consumer
validation and handling are unchanged. A stable private subscription ID lets
a replacement worker remove an old registration before it subscribes again.

Consumer shutdown removes the worker, timer, and subscription. Consumers monitor
their workers and restore them after private subscription-group failure. The
public `subscribed` field changes when the consumer processes status messages;
a busy handler can delay that field update while its worker recovers separately.

Recovery restores future observations. It does not replay missed observations
or change the contract for ordinary public Bus subscribers.
