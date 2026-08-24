# Durable Jidoka Agent Endpoints

Jido Messaging stores the durable messaging projection for a Jidoka agent.
Jidoka remains the source and owner of the agent definition and runtime.

## Ownership

Jido Messaging owns:

- the canonical messaging principal reference;
- the Jidoka messaging endpoint record;
- room membership;
- thread-to-endpoint routing;
- endpoint availability projection;
- message delivery boundaries;
- opaque Jidoka session, request, and turn references.

Jidoka owns:

- the agent definition and process;
- models, prompts, tools, and controls;
- sessions, memory, snapshots, and resume;
- turn execution and runtime events;
- private credentials and environment data.

The core package does not depend on Jidoka or `jido_harness`. A Jidoka-owned
adapter or a separate integration package depends on Jido Messaging and
implements `Jido.Messaging.AgentEndpointProvider`.

## Records

`Jido.Messaging.AgentMessagingEndpoint` binds an agent principal to an opaque
reference with this shape:

```elixir
%{"system" => "jidoka", "id" => "support-agent"}
```

Only the system and ID fields are permitted. The endpoint stores lifecycle and
availability data. Availability is an application projection. Jido Messaging
does not contact Jidoka to calculate it.

`Jido.Messaging.RoomMembership` binds the endpoint and its principal to one
room. Membership does not grant read, post, invoke, or transcript actions.
Those permissions belong to the principal grant and invocation policy work.

`Jido.Messaging.AgentThreadRoute` binds one thread to one endpoint. It can keep
short opaque Jidoka session, request, and turn references. These fields do not
store Jidoka records or runtime state.

## Registration and routing

The principal must exist as an agent participant during the additive identity
compatibility phase.

```elixir
{:ok, endpoint} =
  Messaging.create_agent_messaging_endpoint(%{
    principal_id: agent_participant.id,
    jidoka_agent_ref: %{"system" => "jidoka", "id" => "support-agent"}
  })

{:ok, membership} =
  Messaging.add_agent_endpoint_to_room(endpoint.id, room.id)

{:ok, route} =
  Messaging.route_thread_to_agent_endpoint(
    thread.id,
    endpoint.id,
    jidoka_session_ref: "session:123"
  )
```

Registration, membership, and routing are idempotent under concurrent calls.
The route does not change `Thread.assigned_agent_id`, register an
`AgentRunner`, or start an agent process.

## Delivery callback

Jido Messaging does not invoke the callback automatically in this phase. The
Jidoka integration must first apply the current messaging authorization rule.
It can then resolve and deliver:

```elixir
{:ok, target} = Messaging.resolve_agent_thread_endpoint(thread.id)

{:ok, receipt} =
  Jido.Messaging.AgentEndpointDelivery.deliver(
    MyApp.JidokaMessagingProvider,
    target,
    message,
    timeout: 5_000,
    context: delivery_context
  )
```

The provider receives a stable delivery ID derived from the endpoint, route,
and canonical message. It must use that ID as an idempotency key. The callback
timeout is at most 30 seconds. A timeout, provider crash, unavailable endpoint,
revoked membership, or revoked route returns a bounded error. Jido Messaging
does not start a substitute agent.

The provider can return short Jidoka correlation references. The integration
can persist them with `put_agent_thread_route_correlations/2` after a successful
authorized delivery.

## Recovery

ETS keeps the contracts for local use and tests. SQLite persists the endpoint,
membership, route, availability, and correlation fields across a messaging
restart. A production persistence adapter implements the optional endpoint,
membership, and route callbacks in `Jido.Messaging.Persistence`.

Recovery reads the durable route. It does not load a Jidoka agent or infer that
an unavailable endpoint is available. The Jidoka integration must publish a
new availability projection before delivery can resume.

## Security and privacy

- Endpoint references permit only a Jidoka system and string ID.
- Metadata rejects functions, process values, agent specifications, handlers,
  models, tools, prompts, tokens, credentials, private keys, environment maps,
  sessions, memory, and snapshots.
- Correlation references are short opaque strings.
- Revoked records remain available for audit, but resolution rejects them.
- Membership is not authorization.
- A successful delivery callback is not an authorization decision.
- Provider options and delivery context are transient and are not persisted by
  these endpoint records.

## Legacy handler path

`register_agent/3`, `assign_thread/3`, and `AgentRunner` remain unchanged for
compatibility. They keep handler functions in `RoomServer` state and are not a
durable Jidoka integration. New Jidoka features must use the endpoint records
and a Jidoka-owned provider.
