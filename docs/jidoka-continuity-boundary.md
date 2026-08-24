# Jidoka Continuity Integration Boundary

Status: implemented contract for issue
[#83](https://github.com/agentjido/jido_messaging/issues/83).

## Decision

Jidoka is the first-party agent authoring and execution surface. Jidoka owns
agent sessions, memory, snapshots, request state, resume work, and handoff
state. Jido Messaging owns rooms, threads, participants, canonical messages,
authorization scope, and the small correlation record that connects a thread
to Jidoka.

The dependency direction is one way:

1. A Jidoka-owned integration writes and resolves Jido Messaging correlation
   records.
2. The integration requests a scoped canonical transcript from Jido
   Messaging.
3. The integration passes the opaque reference and messages to Jidoka public
   APIs.

Jido Messaging does not call Jidoka. It has no Jidoka or `jido_harness`
dependency.

This boundary follows the first-party Jidoka guidance for
[architecture boundaries](https://github.com/agentjido/jidoka/blob/main/guides/architecture-boundaries.md),
[sessions and stores](https://github.com/agentjido/jidoka/blob/main/guides/sessions-and-stores.md),
[snapshots and resume](https://github.com/agentjido/jidoka/blob/main/guides/snapshots-and-resume.md),
[memory](https://github.com/agentjido/jidoka/blob/main/guides/memory.md), and
[handoffs](https://github.com/agentjido/jidoka/blob/main/guides/handoffs.md).

## Ownership

| Concern | Owner | Jido Messaging record |
| --- | --- | --- |
| Room and thread | Jido Messaging | Canonical room and thread IDs |
| Agent principal | Jido Messaging | Canonical agent participant ID |
| Canonical transcript | Jido Messaging | Message records in one authorized thread |
| Session and request history | Jidoka | Opaque session and request IDs only |
| Memory and prompt assembly | Jidoka | None |
| Snapshot data and resume | Jidoka | Opaque snapshot ID only |
| Agent handoff state | Jidoka | Opaque transition reference only |

## Contract

`JidokaContinuityRef` contains:

- one integration ID;
- a fixed `%{system: :jidoka, id: ...}` agent reference;
- one Jidoka session ID;
- optional request, turn, snapshot, and expiry references.

`ThreadContinuityLink` adds the messaging room, thread, and agent principal.
It also adds a sequential source revision, source time, availability status,
safe reason code, and optional transition reference. The link ID is stable for
the room and thread.

Both constructors use an allow list. They reject extra fields. Session data,
memory entries, prompts, serialized snapshots, provider clients, credentials,
and arbitrary metadata are not valid input.

## Write and replacement rules

- The first source revision is `1`.
- A byte-equivalent source revision is idempotent.
- Each changed write increments the revision by one.
- Conflicting, stale, and skipped revisions return different errors.
- A principal, Jidoka agent, or session replacement needs a non-secret opaque
  `transition_ref`.
- One live `{integration_id, session_id}` can belong to only one messaging
  thread in one messaging instance.
- `:expired`, `:deleted`, and `:cleared` are terminal for the same session.
  A later active link must identify a replacement session or agent and include
  a transition reference.
- Terminal links remove request, turn, and snapshot references. They keep the
  stable session reference as a durable correlation and deletion marker.

The ETS and SQLite adapters enforce the same rules. SQLite persists the link
across a messaging restart. Room or principal deletion removes its orphaned
link.

## Read and authorization rules

Every link read and transcript request needs an instance-bound
`HistoryScope`. The link room must be in the supplied room list. Jido
Messaging checks that scope before it reads messages. A cursor from another
room or thread cannot expand the result.

`jidoka_continuity_context/3` returns a `JidokaContinuityContext` with the link
and canonical messages for the linked thread. It does not return a prompt or
memory projection. The caller must authorize the rooms before it builds the
scope. Jido Messaging does not make this policy decision.

The resolver also requires an active messaging thread and a live link:

| Stored or effective state | Result |
| --- | --- |
| Missing link | `{:error, :not_found}` |
| Active | Opaque `JidokaContinuityRef` |
| Unavailable | `{:error, {:continuity_unavailable, reason}}` |
| Expired | `{:error, {:continuity_expired, reason}}` |
| Deleted | `{:error, {:continuity_deleted, reason}}` |
| Cleared | `{:error, {:continuity_cleared, reason}}` |
| Closed or archived messaging thread | `{:error, {:continuity_thread_not_active, status}}` |

An `expires_at` value has read-time effect. A Jidoka-owned integration should
also write an explicit terminal state when it confirms deletion or expiry.

## Handoff and recovery

The `transition_ref` is a correlation value, not a handoff record. Jidoka
creates and interprets it. Jido Messaging only uses its presence to approve an
identity replacement. It does not copy Jidoka ownership, private context, or
handoff state.

After a Jido Messaging restart, the integration can resolve the same session
ID and request a scoped canonical transcript. Jidoka then decides whether to
load, recover, fork, or reject its session. A missing Jidoka session must be
reported back with `set_thread_continuity_status/4`; Jido Messaging does not
attempt recovery.

## Compatibility and follow-up work

The core contract uses the existing agent participant and `HistoryScope`
types, so it does not need a Jidoka package. Future Jidoka-owned integration
work can align the opaque agent reference with the canonical principal and
endpoint contracts from issues
[#77](https://github.com/agentjido/jido_messaging/issues/77) and
[#78](https://github.com/agentjido/jido_messaging/issues/78). Authorization
grants and activity projections remain separate concerns.

Applications must not put private Jidoka values in message, thread, or bridge
metadata as a workaround. The strict continuity types are the only supported
messaging-side continuity record.
