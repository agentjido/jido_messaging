# Principal Messaging Authorization

Jido Messaging owns authorization for messaging resources and effects. Jidoka
owns agent runtime controls, tools, models, review, and execution decisions.
The two policy systems have separate purposes and neither system implies a
decision in the other.

## Contracts

`Jido.Messaging.Membership` records that a canonical principal is a member of a
canonical room. Membership is durable and revisioned. Membership does not
grant an action.

`Jido.Messaging.Grant` is an allow grant for one principal. It contains:

- an issuer principal ID;
- a closed list of messaging actions;
- a canonical bridge, room, thread, message, or transcript scope;
- active, suspended, or revoked status;
- optional start and expiry times;
- enforced constraints;
- a monotonic revision.

Core has no grant cache. `Jido.Messaging.Authorizer.check/4` reads current
persistence state for each decision. A decision contains the exact grant and
invocation-policy revisions. It is not a reusable capability token.

`Jido.Messaging.InvocationPolicy` adds a second gate for `:invoke_agent`. Its
mode is one of:

- `:controller_only`;
- `:allowlist`;
- `:room_members`;
- `:anyone`;
- `:nobody`.

Every caller still needs a matching `:invoke_agent` grant. The policy does not
add an action grant. Participant type, display data, trust evidence, and
authorship evidence do not authorize invocation.

## Example

```elixir
thread_scope =
  Jido.Messaging.AuthorizationScope.new(%{
    kind: :thread,
    room_id: room.id,
    thread_id: thread.id,
    target_principal_id: agent_principal.id
  })

{:ok, _membership} =
  Messaging.create_membership(%{
    principal_id: controller_principal.id,
    room_id: room.id,
    issuer_principal_id: host_admin_principal.id
  })

{:ok, _grant} =
  Messaging.create_principal_grant(%{
    principal_id: controller_principal.id,
    issuer_principal_id: host_admin_principal.id,
    actions: [:invoke_agent],
    scope: thread_scope
  })

{:ok, _policy} =
  Messaging.create_invocation_policy(%{
    target_principal_id: agent_principal.id,
    issuer_principal_id: host_admin_principal.id,
    scope: %{kind: :room, room_id: room.id},
    mode: :controller_only,
    controller_principal_id: controller_principal.id
  })

{:ok, decision} =
  Messaging.authorize(
    controller_principal.id,
    :invoke_agent,
    thread_scope
  )
```

An invocation policy can contain a room scope while a caller grant contains a
narrow thread scope. Both checks must pass. A thread grant does not authorize
the same action for the full room.

## Jidoka integration sequence

A Jidoka-owned adapter or integration package must:

1. check the caller `:invoke_agent` grant and invocation policy;
2. check the agent principal `:receive_message` grant for the same canonical
   message scope;
3. pass `AuthorizationDecision.to_map/1` and the route correlation references
   to Jidoka as trusted integration context;
4. check the agent principal again before each later messaging effect, such as
   `:post_message` or `:read_transcript`.

The adapter must not reuse a decision after queued work, a restart, or a policy
change. It must not pass wider scope or authority to Jidoka. Jido Messaging
does not copy Jidoka tool controls or runtime policy, and core has no Jidoka or
`jido_harness` dependency.

## ChatActions migration

`Jido.Messaging.ChatActions.context/3` supports two explicit modes:

- `:legacy` preserves the existing scope and visible-write policy behavior;
- `:enforce` requires a verified principal ID, a canonical authorization
  scope, and a current durable grant.

The default is `:legacy` for compatibility. A host opts into enforcement with
trusted context, not action parameters:

```elixir
context =
  Jido.Messaging.ChatActions.context(Messaging, active_context,
    scope: provider_scope,
    policy: visible_write_policy,
    principal_id: agent_principal.id,
    authorization_mode: :enforce,
    authorization_scope: canonical_thread_scope
  )
```

The durable grant check runs before the provider call. The current
`ChatActions.Policy` still runs for visible writes. Both gates must allow the
effect.

## Constraints and limits

Grant constraints are closed and enforced. `requires_membership` defaults to
`true` for room-based resources. A host can set it to `false` only for a
controlled non-member integration. `max_results` is returned in the effective
decision and the caller must clamp a transcript or list request to that value.

Unknown constraint keys are rejected. Metadata rejects executable values and
keys for secrets, tokens, credentials, models, tools, prompts, handlers,
sessions, snapshots, and environment data.

## Revision and recovery rules

Memberships, grants, and invocation policies start at revision 1. Each status
or policy change increments the revision. Updates require the current expected
revision. A stale update fails with `{:stale_revision, current_revision}`.

ETS supplies isolated local state. SQLite restores records and revisions after
a restart. Other production adapters implement the optional authorization
callbacks in `Jido.Messaging.Persistence`. PostgreSQL support must use atomic
compare-and-set updates for revisions.

Room or principal deletion removes its authorization records. Normal
revocation keeps the record and increments its revision for audit and recovery.
