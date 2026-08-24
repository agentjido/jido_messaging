# Jidoka-Backed Delegation Messaging

Status: implemented transport contract for issue
[#84](https://github.com/agentjido/jido_messaging/issues/84).

## Decision

Jidoka is the first-party agent authoring and execution surface. It owns agent
selection, subagent execution, handoff ownership, forwarded context, operation
results, cancellation, and routing decisions. Jido Messaging transports and
records small references when those decisions cross a messaging boundary.

Jido Messaging does not add a delegation state machine. It does not call
Jidoka and has no Jidoka or `jido_harness` dependency. A later Jidoka-owned
adapter can consume this contract and call Jidoka public APIs.

This boundary starts with the first-party Jidoka contracts:

- [Agent Orchestration](https://github.com/agentjido/jidoka/blob/main/guides/agent-orchestration.md)
  defines a subagent as bounded work inside the current turn and a handoff as
  ownership of future turns.
- [Handoffs](https://github.com/agentjido/jidoka/blob/main/guides/handoffs.md)
  states that Jidoka stores the owner and that the application routes the next
  turn.
- [`Jidoka.Handoff`](https://github.com/agentjido/jidoka/blob/main/lib/jidoka/handoff.ex)
  defines the canonical handoff ID, conversation ID, source, target, request,
  and context fields.
- [`Jidoka.Event`](https://github.com/agentjido/jidoka/blob/main/lib/jidoka/event.ex)
  uses request ID and sequence to order one turn event stream.
- [Turn and Effect Contracts](https://github.com/agentjido/jidoka/blob/main/guides/turn-and-effect-contracts.md)
  defines effect IDs, request IDs, loop indexes, and operation results.

## Why a messaging envelope is needed

The full Jidoka handoff and operation result shapes can contain forwarded
context, task text, summaries, arbitrary metadata, and operation output. Those
values are not safe transport contracts for a room, bridge, or remote
endpoint.

`JidokaDelegationEvent` is an immutable allow-listed envelope. It contains:

- one `JidokaDelegationRef` for a subagent effect or canonical handoff;
- one `JidokaEmissionRef` for the Jidoka event, handoff, or operation result;
- source and target messaging principal IDs;
- exact messaging room and thread IDs;
- an explicit list of related canonical message IDs;
- an opaque route reference or safe reason code when required;
- a transport ID and bounded visited-node trace.

It cannot contain a task, context, result, output, owner record, prompt,
memory, credentials, provider client, or executable agent module.

## Jidoka source mapping

The Jidoka-owned adapter chooses one messaging action for one canonical Jidoka
source. It must not create several interpretations of the same source.

| Messaging action | Delegation kind | Required Jidoka source |
| --- | --- | --- |
| `:requested` | Subagent or handoff | `Jidoka.Event` request ID and sequence |
| `:result` | Subagent | Operation result request and effect IDs |
| `:accepted` | Handoff | Canonical `Jidoka.Handoff.id` |
| `:route_changed` | Handoff | Canonical `Jidoka.Handoff.id` plus opaque route ref |
| `:cancelled` | Subagent or handoff | `Jidoka.Event` request ID and sequence plus reason code |
| `:route_cleared` | Handoff | A stable Jidoka event reference plus opaque route ref |

The envelope ID is derived from the delegation, emission, and action. An
event emission ID is derived from `{request_id, seq}`, which is the Jidoka
ordering contract. A handoff uses its canonical handoff ID. An operation
result uses its request and effect IDs.

The current Jidoka handoff reset API does not supply a canonical handoff-reset
record. An adapter must not invent a `:route_cleared` source. It can use that
action only when Jidoka supplies a stable event that represents the reset.

## Authorization and context

`JidokaDelegationScope` is exact and instance-bound. It names the room,
thread, source principal, target principal, and non-secret authorization
references for both principals. The host authorization layer creates it only
after it checks room and thread grants. The scope itself is an attestation,
not a grant evaluator or credential.

Jido Messaging checks the full scope before it reads a room, thread,
participant, or message. Both principals must be canonical agent
participants. Every related message must belong to the exact room and thread.
A sibling thread, parent-room message, or another room fails closed.

`jidoka_delegation_context/2` returns only the immutable event and the
canonical messages explicitly named by that event. It does not load the full
thread and does not project Jidoka context. A Jidoka-owned adapter decides what
public context, if any, to forward through Jidoka's own `forward_context`
contract.

The opaque authorization references are not copied into the durable event.
Future principal-grant work can produce these scopes without changing the
transport contract.

## Duplicate, loop, and cancellation safety

- A retry of the same envelope is idempotent.
- One transport ID can identify only one event in a messaging instance.
- One canonical Jidoka emission can produce only one messaging event.
- A changed retry of the same event fails as a conflict.
- Each transport boundary appends its node ID.
- A repeated node fails as `:delegation_transport_loop`.
- The trace has a maximum of 16 nodes.
- A durable cancellation marker blocks later requested, accepted, result, or
  route-change delivery for the same delegation ID.
- Route clearing and cancellation records can still cross after a messaging
  thread closes. Other deliverable records require an active thread.

ETS and SQLite enforce the same immutable and cancellation rules. SQLite keeps
both the event and its cancellation protection across a messaging restart.
Room deletion removes its transport records.

## Routing boundary

A `:route_changed` record is a transport directive from a canonical Jidoka
handoff. It does not mutate `Thread.assigned_agent_id`, start `AgentRunner`, or
write Jidoka ownership. This prevents Jido Messaging from creating a competing
owner.

The future Jidoka-owned adapter can consume the directive, resolve the target
Jidoka endpoint, and update its delivery route after it applies current
principal grants. Endpoint integration can align with issues
[#77](https://github.com/agentjido/jido_messaging/issues/77),
[#78](https://github.com/agentjido/jido_messaging/issues/78), and
[#79](https://github.com/agentjido/jido_messaging/issues/79) after those
contracts land. Core Messaging remains independent of them.

## Compatibility and limits

This branch is independent of the other roadmap branches. It uses existing
rooms, threads, participants, and messages. Custom persistence adapters can
omit the optional delegation callbacks; the public API then returns
`:jidoka_delegation_persistence_not_supported`.

This contract is not an instruction to copy a Jidoka handoff into message
metadata. Applications must keep private Jidoka context and operation output
inside Jidoka. If the target needs user-visible content, commit it as a
canonical message first and transport its message ID.
