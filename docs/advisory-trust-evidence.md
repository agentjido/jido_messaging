# Advisory Trust Evidence for Jidoka Agents

Status: implemented contract for issue
[#85](https://github.com/agentjido/jido_messaging/issues/85).

## Decision

Jido Messaging stores and returns scoped evidence. It does not decide whether
an agent is suitable for work. A host application or a Jidoka-owned adapter can
inspect the evidence during its own selection process.

The boundary follows these first-party Jidoka contracts:

- [Agent Spec Contract](https://github.com/agentjido/jidoka/blob/main/guides/agent-spec-contract.md)
  defines the stable Jidoka agent specification ID and keeps live runtime data
  out of the specification.
- [`Jidoka.agent/1`](https://github.com/agentjido/jidoka/blob/main/lib/jidoka.ex)
  returns immutable agent definition data, not a process or live capability.
- [Jido Process Integration](https://github.com/agentjido/jidoka/blob/main/guides/jido-process-integration.md)
  states that process registry IDs are not global identity outside one Jidoka
  runtime.

For this reason, evidence carries both a canonical messaging principal ID and
an opaque `%{"system" => "jidoka", "id" => agent_id}` reference. The host owns
the binding between them. Jido Messaging does not import an agent definition,
resolve a process, or start an agent.

Core Messaging has no Jidoka or `jido_harness` dependency. A later integration
belongs in Jidoka or in a host-owned adapter.

## Evidence Contract

`TrustEvidence` is an allow-listed advisory record. It contains:

- one exact room ID;
- the subject messaging principal and Jidoka agent reference;
- one canonical issuer principal;
- a non-empty list of safe capability codes;
- one factual outcome: `:succeeded`, `:failed`, `:denied`, `:cancelled`, or
  `:inconclusive`;
- one canonical message or provider-record source;
- a source revision;
- a verification state and an opaque verification reference when required;
- an observation time and mandatory expiry.

It cannot contain a numeric score, rank, confidence value, recommendation,
prompt, result, model output, memory, credential, grant, or executable module.

The verification state is `:unverified`, `:verified`, `:disputed`, or
`:revoked`. Verification says what the issuer or provider asserts about the
source. It does not make the claim true. Consumers must consider issuer,
source, verification state, expiry, and room scope together.

## Immutable Sources and Revisions

A claim ID is derived from the room, subject, issuer, capability scope, and
source identity. Each source revision has a separate evidence ID.

- An exact retry is idempotent.
- Changed data at the same source revision is a conflict.
- A higher source revision is append-only.
- A normal query returns the highest revision of each claim.
- `include_history: true` returns retained earlier revisions.

This keeps corrections and disputes visible without overwriting prior source
revisions.

A message source must identify a canonical message in the same room, and that
message must have the issuer as its canonical sender. Jido Messaging validates
this relation when it records the evidence. A provider record uses a safe
provider ID and an opaque source ID. It does not contain the source payload.
Jido Messaging does not resolve or fetch the opaque provider source ID. Hosts
must use tenant-scoped IDs without credentials.

## Authorization, Membership, and Transcript Scope

`TrustEvidenceScope` is exact and instance-bound. It names one room, one
requester, one subject principal, and one Jidoka agent reference. It also
requires non-empty requester authorization references and subject membership
references.

The host creates the scope only after it checks current room access and agent
membership. The references are attestations of that check. They are not
credentials and they are not stored with the evidence.

Jido Messaging validates the full scope before it reads the room, participant,
message, stored evidence, or external provider. The subject must be a canonical
agent participant. An issuer cannot issue evidence about itself. A query cannot
return evidence for another room, principal, or Jidoka agent reference.

This branch is independent of the other roadmap branches. When the principal,
room-membership, grant, activity, and discovery contracts from issues
[#77](https://github.com/agentjido/jido_messaging/issues/77),
[#78](https://github.com/agentjido/jido_messaging/issues/78),
[#79](https://github.com/agentjido/jido_messaging/issues/79),
[#81](https://github.com/agentjido/jido_messaging/issues/81), and
[#82](https://github.com/agentjido/jido_messaging/issues/82) land, a host can
use those records to create the scope. Evidence itself still cannot change a
grant, membership, endpoint, or route.

## Explainable Query Results

`query_trust_evidence/2` returns `TrustEvidenceResult` with one of three
statuses:

| Status | Meaning |
| --- | --- |
| `:evidence` | The provider was available and returned current matching evidence. |
| `:no_evidence` | The provider was available but returned no current matching evidence. |
| `:unavailable` | The provider could not answer or returned invalid data. |

The result lists `outcomes_present`. Failed and denied records remain explicit
negative evidence. An unavailable provider never becomes no evidence, and no
evidence never becomes positive evidence.

Queries can filter by capability, verification state, expiry, and source
history. They have a bounded limit. They do not calculate totals, averages,
rates, scores, ranks, or recommendations. Activity volume is not quality.

## Provider Boundary

`TrustEvidenceProvider` lets a host query another evidence store. The host
selects the provider module from trusted application code. User or agent input
must never select an executable module.

The provider returns only `TrustEvidence` structs. Jido Messaging then checks
each derived ID, room, subject principal, Jidoka agent reference, and local
issuer. A scope mismatch makes the provider result unavailable. Raw provider
errors are not returned to the caller.

An application can query a provider like this:

```elixir
{:ok, result} =
  MyApp.Messaging.query_trust_evidence(scope,
    provider: MyApp.ReviewEvidenceProvider,
    provider_opts: [tenant: tenant_id]
  )
```

The provider option is an integration point. It is not a Jidoka agent module
and it cannot start or select an agent.

## Validation Experiment

Create a reviewed outcome in one room and record it:

```elixir
{:ok, scope} =
  MyApp.Messaging.trust_evidence_scope(%{
    room_id: room.id,
    requester_principal_id: reviewer.id,
    subject_principal_id: support_agent.id,
    subject_jidoka_agent_ref: %{system: :jidoka, id: "support-agent"},
    requester_authorization_refs: ["grant:reviewer:room"],
    subject_membership_refs: ["membership:support-agent:room"]
  })

{:ok, _evidence} =
  MyApp.Messaging.record_trust_evidence(
    %{
      room_id: room.id,
      subject_principal_id: support_agent.id,
      subject_jidoka_agent_ref: %{system: :jidoka, id: "support-agent"},
      issuer_principal_id: reviewer.id,
      capability_scope: ["customer_support"],
      outcome: :succeeded,
      source: %{kind: :message, id: review_message.id, revision: 1},
      verification_state: :verified,
      verification_ref: "review:approved:123",
      observed_at: review_message.inserted_at,
      expires_at: DateTime.add(review_message.inserted_at, 30, :day)
    },
    scope
  )

{:ok, result} = MyApp.Messaging.query_trust_evidence(scope)
```

Confirm that the host can inspect `result.evidence`, that a failed outcome stays
visible as negative evidence, and that a different room scope cannot read it.
Then confirm that no function in this contract ranks, selects, invokes, or
grants authority to the subject agent.

## Security and Privacy Limits

- Evidence is a claim, not proof. False claims and collusion remain possible.
- Room scope prevents a global public reputation graph by default.
- Mandatory expiry and a maximum 366-day lifetime limit stale evidence.
  Consumers must still define a retention policy.
- Deleting a room or either participant removes its ETS or SQLite evidence.
- A deleted source message can leave an opaque source ID until the evidence is
  deleted or expires. Message content is never copied into evidence.
- Capability codes can still reveal sensitive work categories. Hosts must use
  the smallest useful vocabulary.
- Reused provider source IDs can correlate activity across communities. Use
  tenant-scoped opaque IDs.
- Do not infer quality from activity volume, missing evidence, or provider
  availability.
- Do not copy global scores, automatic ranking, paid endorsements, or evidence
  that changes authorization.
