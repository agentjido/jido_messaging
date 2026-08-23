# Agentic Identity

Jido Messaging separates chat presentation, canonical identity, provider
identity, and message authorship. This separation supports humans, agents, and
systems without making the messaging package an agent runtime.

## Contracts

`Jido.Chat.Participant` remains the chat-facing record. Its ID is also the
principal ID during the additive compatibility phase.

`Jido.Messaging.Principal` stores:

- participant and principal IDs;
- human, agent, or system type;
- optional controller principal;
- verification and credential state;
- active, suspended, or revoked lifecycle state;
- an optional opaque external agent reference.

`Jido.Messaging.ExternalIdentityBinding` binds one provider identity to one
principal. Its unique identity key is:

```text
{channel, bridge_id, external_id}
```

The bridge ID is required. Two provider accounts with the same user ID in two
workspaces do not become one identity. Trusted application code must create an
explicit second binding when the accounts belong to the same principal.
Persistence adapters must implement the optional principal and external
identity callbacks to support these typed records. Older adapters continue to
support ingest and message-time authorship, but the typed binding APIs return
`:unsupported` and authorship does not claim a durable binding record.

`Jido.Messaging.Authorship` is an immutable message-time assertion. It stores
the principal, participant, binding reference, assurance, proof reference, and
optional runtime execution ID. New inbound messages store it in message
metadata. Old messages are projected as asserted authorship.

## Assurance

Assurance increases in this order:

1. `:asserted`
2. `:provider_verified`
3. `:application_verified`
4. `:cryptographically_verified`

Ingest defaults to `:asserted`. A security adapter must return an explicit
`identity_assurance` value to use a higher value. A normal allow decision does
not imply verification. A stronger binding assurance does not change the
message-time assurance of a later message that has weaker evidence.

`identity_proof_ref` must identify proof stored in a suitable audit system. It
must not contain the proof, a signature, a token, or a credential. Jido
Messaging accepts only a short string reference.

## Lifecycle and control

A principal can name another active principal as its controller. A principal
cannot control itself. Controller identity does not grant messaging authority;
authorization grants are a separate contract.

A revoked external identity binding remains readable for audit. It cannot be
used to resolve a new inbound message and cannot be reactivated by normal
ingest. Trusted code must make an explicit lifecycle change if reactivation is
required.

## Transcript resolution

Transcript entries resolve provider participant identity from the scoped
binding. They do not select an ID from `Participant.external_ids` when a typed
binding is available. The old map remains a compatibility fallback for legacy
messages and data.

This rule prevents a transcript from showing a Slack user ID from workspace A
on a message that came from workspace B.

## Jidoka boundary

Jidoka is the first-party agent authoring and execution surface. A principal can
hold an opaque reference such as:

```elixir
%{"system" => "jidoka", "id" => "support-agent"}
```

The reference is identity data only. Jido Messaging does not store
`Jidoka.Agent.Spec`, tools, prompts, model settings, memory, sessions, or resume
state. It does not execute or select an agent. A Jidoka-owned adapter or a
separate integration package owns that mapping. The core has no Jidoka or
`jido_harness` dependency.

## Privacy and migration

- Do not merge identities by name, display name, or email address.
- Do not put provider credentials or private controller data in public
  metadata.
- Treat provider user IDs as tenant-local unless the provider contract states
  otherwise.
- Keep existing `Participant.id` and `Message.sender_id` values.
- Treat messages without typed authorship as `:asserted`.
- Create explicit scoped bindings before traffic starts when old data used
  unscoped provider identities.
