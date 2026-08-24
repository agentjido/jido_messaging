# Jidoka Agent Discovery Projection

Jido Messaging provides a small, safe directory projection for Jidoka agents.
Jidoka stays the source of agent definitions and capability data. Jido
Messaging stores only the data that a messaging client needs for discovery.

## Ownership boundary

Jidoka owns:

- `Agent.Spec` and agent versions;
- instructions, models, tools, controls, and credentials;
- process hosting, availability inputs, sessions, memory, and execution;
- the decision about which source fields are safe to publish.

Jido Messaging owns:

- the canonical messaging principal reference;
- the canonical messaging endpoint reference;
- the scoped directory query contract;
- the safe display projection and its source revision;
- persistent ETS and SQLite projection records.

Jido Messaging does not depend on Jidoka or `jido_harness`. A Jidoka-owned
integration package depends on Jido Messaging and implements
`Jido.Messaging.AgentDirectoryProjector`.

## Projection contract

`Jido.Messaging.AgentDirectoryProjection` accepts only these source fields:

- an opaque Jidoka agent reference with `system` and `id`;
- a canonical messaging principal ID;
- an optional canonical messaging endpoint reference;
- a safe name and description;
- at most 32 safe capability codes;
- an availability summary and agent version;
- a small invocation mode and approval summary;
- an integration-reported verification state;
- a listing state, source revision, source time, and bounded freshness period.

The Jidoka reference has this shape:

```elixir
%{"system" => "jidoka", "id" => "support-guide"}
```

The endpoint reference has this shape:

```elixir
%Jido.Messaging.AgentDirectoryEndpointRef{
  system: "jido_messaging",
  id: "endpoint:support-guide"
}
```

The projection does not accept an agent specification, instructions, prompts,
models, tools, functions, controls, credentials, tokens, private keys,
environment data, sessions, memory, or runtime records. The name, description,
and capability codes are still an integration trust boundary. The Jidoka
adapter must create redacted display text. It must not copy instruction text
or tool configuration into these fields.

## Publishing from Jidoka

A Jidoka-owned adapter can map its source data to a projection:

```elixir
defmodule MyApp.JidokaDirectoryProjector do
  @behaviour Jido.Messaging.AgentDirectoryProjector

  @impl true
  def to_directory_projection(agent_spec, context, _opts) do
    {:ok,
     %{
       jidoka_agent_ref: %{system: :jidoka, id: context.agent_id},
       principal_id: context.principal_id,
       endpoint_ref: %{system: :jido_messaging, id: context.endpoint_id},
       name: context.safe_name,
       description: context.safe_description,
       capabilities: context.safe_capability_codes,
       availability: context.availability,
       version: context.version,
       invocation_summary: %{mode: :thread, approval: :may_require},
       verification_state: :verified,
       listing_state: :listed,
       source_revision: context.revision,
       source_updated_at: context.source_updated_at,
       fresh_for_seconds: 300
     }}
  end
end

{:ok, projection} =
  MyApp.Messaging.project_jidoka_agent_from(
    MyApp.JidokaDirectoryProjector,
    jidoka_agent_spec,
    safe_projection_context
  )
```

The adapter source and context are transient. The strict projection
constructor validates the returned map before persistence. An integration can
also call `project_jidoka_agent/1` with a map that it has already redacted.

The first source revision is `1`. Later revisions must be sequential. Equal
content at the same revision is idempotent. Conflicting equal revisions, old
revisions, and revision gaps fail. This prevents old availability or endpoint
data from replacing a newer projection.

Use `listing_state: :withdrawn` at a new revision to remove an agent from
search without loss of the revision marker.

## Scoped discovery

Agent search always needs an `AgentDirectoryScope`. The scope maps endpoint
IDs to principal IDs:

```elixir
{:ok, scope} =
  MyApp.Messaging.agent_directory_scope(%{
    "endpoint:support-guide" => "principal:support-guide"
  })

{:ok, entries} =
  MyApp.Messaging.search_jidoka_agents(
    %{capability: "support", invokable: true},
    scope,
    limit: 20
  )
```

An application must build the map from current active room memberships and a
current authorization result. It must not build it from user input. After the
principal grant and durable endpoint work is integrated, the Jidoka adapter
must use those contracts to construct the scope. The directory does not create
membership or grant access.

Search returns a projection only when its endpoint and principal pair is in
the supplied scope. A projection without an endpoint is not returned. This
lets an integration store a safe Jidoka projection before it has a usable
messaging binding without presentation of the agent as invokable.

`directory_search(:agent, query, scope: scope)` and
`directory_lookup(:agent, query, scope: scope)` use the same rules. Existing
participant and room directory queries do not change.

## Freshness and invocation

Each result reports `freshness` as `:fresh` or `:stale`. `invokable` is true
only when all of these conditions are true:

- the projection is listed;
- the scoped endpoint exists in the result;
- projected availability is `:available`;
- verification is not rejected;
- the freshness period has not ended.

`invokable` is a user interface hint. It is not an authorization decision.
The caller must get a current invocation decision before it sends a request.
The verification state is also an integration-reported display value. It does
not prove controller identity, grant access, or establish reputation.

Availability can differ from the current Jidoka runtime. A short freshness
period and frequent revision updates reduce this risk. Freshness is limited to
24 hours. Source times more than five minutes in the future fail validation.

## Persistence and compatibility

ETS and SQLite store the same safe projection. SQLite keeps projections across
a messaging restart. Deletion of a canonical participant also deletes its
directory projection.

The new persistence callbacks are optional. A custom persistence adapter that
does not implement them returns `{:error, :unsupported}` from the projection
API. The PostgreSQL adapter must add these callbacks when the persistence work
is combined.

The current additive implementation validates the principal through the agent
participant record. After canonical principals and durable Jidoka endpoints
are merged, the integration must align this validation with those records.
When the endpoint callbacks are present, publication also checks that the
endpoint is active and belongs to the projected principal.

## Security and privacy rules

- Do not put `Agent.Spec`, prompts, tools, controls, or private runtime data in
  the projection.
- Do not show an endpoint that is not in the current caller scope.
- Do not treat projected capability, verification, availability, or
  `invokable` as authorization.
- Do not expose room membership, controller identity, or grant details in a
  directory result.
- Publish a withdrawal revision when an agent must no longer be discoverable.
- Keep the freshness period short enough for the Jidoka availability source.
- Keep source revision state durable so that old events cannot publish stale
  data again.
