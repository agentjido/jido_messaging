# Jidoka Activity Projection

Jido Messaging can store a small activity projection that links messaging
history to a Jidoka request and turn. This projection is for operator history,
navigation, and correlation. It is not a second agent runtime journal.

Jidoka remains the source of truth for model calls, tool calls, control flow,
memory, prompts, turn state, and execution results.

## Ownership Boundary

A trusted Jidoka-owned adapter or separate integration package maps selected
`Jidoka.Event` or `Jidoka.Trace` data to the messaging projection. The adapter
calls `project_messaging_activity/1` with redacted fields. Jido Messaging does
not import a Jidoka event module and does not read the Jidoka journal directly.

Jidoka is the only first-party agent authoring and execution surface for this
integration. The messaging core does not start an agent, import a Jidoka agent
specification, or depend on Jidoka or `jido_harness`.

## Projection Contract

`Jido.Messaging.MessagingActivityEntry` contains:

- The canonical messaging principal, room, optional thread, and optional
  message IDs.
- A safe activity kind and status.
- A bounded `MessagingActivitySummary` with an outcome enum, safe code, and
  optional redacted label.
- A `JidokaExecutionRef` with integration, session, request, turn, handoff, and
  approval IDs.
- An opaque detail reference and explicit detail availability.
- Jidoka source event ID, event type, revision, and recorded time.

The input is strict. It rejects unknown top-level fields, unknown summary
fields, and unknown execution reference fields. A complete event, trace,
prompt, tool argument, model output, or memory object therefore cannot enter
the projection by mistake. It also rejects an outcome that conflicts with the
safe activity status.

The optional summary label can still contain sensitive text if an adapter puts
it there. The Jidoka-owned adapter must redact the label before it calls Jido
Messaging. Prefer an outcome enum and a stable reason code when a label is not
needed.

## Trusted Projection Input

The adapter can project an inbound request like this:

```elixir
{:ok, entry} =
  MyApp.Messaging.project_messaging_activity(%{
    principal_id: agent_principal.id,
    room_id: room.id,
    thread_id: thread.id,
    message_id: inbound_message.id,
    kind: :request,
    status: :running,
    summary: %{
      outcome: :none,
      code: "request.accepted"
    },
    execution_ref: %{
      integration_id: "jidoka:primary",
      session_id: jidoka_session_id,
      request_id: jidoka_request_id,
      turn_id: jidoka_turn_id,
      approval_id: jidoka_approval_id,
      detail_ref: "jidoka://trace/turn-123",
      detail_availability: :available,
      detail_expires_at: detail_retention_deadline
    },
    source_event_id: jidoka_event_id,
    source_event_type: "jidoka.turn.started",
    source_revision: jidoka_event_revision,
    source_recorded_at: jidoka_event_time
  })
```

The API requires an agent messaging principal. It also validates the canonical
room, thread, and message when it creates an entry. The linked message can be
from a human or an agent. Projection does not change message authorship.

An update with the same source revision and data is idempotent. Different data
at the same revision is a conflict. A lower revision is stale. A higher
revision can update status, summary, or detail availability, but it cannot
change messaging scope or Jidoka execution correlation.

After initial validation, a higher revision can mark detail unavailable even
if the linked message has already reached its retention limit. The room and
principal still control the query scope.

## Scoped Activity History

Activity history uses the same mandatory `HistoryScope` as participant
transcripts:

```elixir
{:ok, scope} = MyApp.Messaging.history_scope(allowed_room_ids)

{:ok, entries} =
  MyApp.Messaging.principal_activity(agent_principal.id, scope,
    limit: 50,
    before: activity_cursor
  )
```

The persistence query receives only the allowed room IDs. A cursor from another
room returns `:cursor_not_found`. A scope from another messaging instance is
rejected. The host must build `HistoryScope` from its current authorization
decision.

This projection does not grant access to Jidoka detail. The host must make a
separate authorization check before it resolves `detail_ref`.

## Detail and Retention Behavior

`detail_availability` is one of:

- `:available`
- `:unavailable`
- `:expired`
- `:restricted`

Available detail requires an opaque `detail_ref`. Unavailable or expired detail
cannot keep a detail reference. If `detail_expires_at` passes before the
adapter sends an update, `principal_activity/3` returns an effective `:expired`
state and hides the detail reference.

The messaging projection and the Jidoka journal can have different retention
periods. Deleting a room or principal deletes its ETS or SQLite activity
projection. Deleting a linked message can leave a safe activity entry with a
stale message reference. This lets an operator see that an activity occurred
without retaining message content or Jidoka execution detail.

ETS and SQLite implement the optional activity persistence callbacks. Other
persistence adapters can return `:unsupported` until they implement the same
callbacks.
