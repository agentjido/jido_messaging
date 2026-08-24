# Controller Identity Credentials

Jido Messaging can store an optional controller credential for a messaging
principal. The credential states that an issuer controls a subject for an exact
audience and a bounded set of rooms. The subject stays the author of its
messages.

The credential is identity evidence. It is not an action grant. A host policy
must make a separate authorization decision for each messaging action.

## Contract

`Jido.Messaging.IdentityCredential` contains these main fields:

- `issuer_principal_id`: The controller or attesting principal.
- `subject_principal_id`: The agent or other messaging principal.
- `purpose`: `:controller`.
- `conditions`: One exact audience and one or more canonical room IDs.
- `provider_id`, `proof_type`, and `proof_ref`: Opaque references for a verifier.
- `key_version_ref`: An optional opaque key version reference.
- `issued_at`, `not_before`, and `expires_at`: An explicit validity window.
- `status` and `revision`: Lifecycle state and optimistic concurrency data.

The record cannot contain raw keys, tokens, proofs, functions, tools, or
environment data. Metadata has a size limit and rejects sensitive key names.

## Create and Verify

First, create a controller and an agent as normal messaging participants. Then
create the credential:

```elixir
now = DateTime.utc_now()

{:ok, credential} =
  MyApp.Messaging.create_identity_credential(%{
    issuer_principal_id: controller.id,
    subject_principal_id: agent.id,
    purpose: :controller,
    conditions: %{
      audience: "my-app:jidoka",
      room_ids: [room.id]
    },
    provider_id: "my-identity-provider",
    proof_type: "ed25519-v1",
    proof_ref: "provider://agents/agent-123",
    key_version_ref: "key-version-7",
    issued_at: now,
    not_before: now,
    expires_at: DateTime.add(now, 3_600, :second)
  })
```

The host supplies a provider module. Jido Messaging passes the proof to this
module only during verification:

```elixir
defmodule MyApp.IdentityProvider do
  @behaviour Jido.Messaging.IdentityProvider

  @impl true
  def verify(credential, proof, context, _opts) do
    case MyApp.Keys.verify(credential.proof_ref, proof, context) do
      :ok ->
        {:ok, %{
          assurance: :verified,
          key_version_ref: credential.key_version_ref,
          metadata: %{method: "host-key-service"}
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Each proof must have a unique assertion ID, a recent `issued_at` value, and the
same proof type and proof reference as the credential:

```elixir
proof = %{
  assertion_id: "assertion-018f...",
  issued_at: DateTime.utc_now(),
  proof_type: credential.proof_type,
  proof_ref: credential.proof_ref,
  signature: transient_signature
}

context = %{
  subject_principal_id: agent.id,
  controller_principal_id: controller.id,
  audience: "my-app:jidoka",
  room_id: room.id
}

{:ok, evidence} =
  MyApp.Messaging.verify_identity_credential(
    credential.id,
    proof,
    context,
    provider: MyApp.IdentityProvider
  )
```

The verifier checks the current credential status, validity, subject,
controller, audience, room, participant records, and room record before it
calls the provider. After provider success, it consumes a SHA-256 assertion
reference. The raw assertion ID and proof are not stored. A second use returns
`:identity_assertion_replayed`.

Provider verification must have no side effects. Concurrent verification can
call the provider more than once, but only one caller can consume the assertion
and receive evidence.

Provider calls have a bounded timeout. Assertion age and clock skew also have
bounded options. Provider errors do not consume the assertion, so a caller can
retry a temporary provider failure.

Verified evidence is valid for 60 seconds by default and for no more than five
minutes. It also cannot outlive the credential. Use `:evidence_valid_for_ms` to
select a shorter interval.

## Authorship and Authorization

`Jido.Messaging.IdentityEvidence` is an ephemeral result. Use
`annotate_message/2` to add it to message metadata:

```elixir
{:ok, message_with_evidence} =
  Jido.Messaging.IdentityEvidence.annotate_message(message, evidence)
```

The function requires `message.sender_id` to equal the credential subject. It
also requires the same room and current evidence. It never changes `sender_id`.

The evidence has separate fields for the author and controller. It does not
have an action, permission, or authorization result. This separation prevents
a valid controller proof from becoming a reusable messaging capability.

For an agent with no credential, call `verify_optional_identity/4` with `nil`.
It returns short-lived `:uncredentialed` evidence. This keeps credentials
optional and lets the host apply a lower assurance policy.

## Lifecycle and Rotation

Use the current revision for each lifecycle change:

```elixir
{:ok, suspended} =
  MyApp.Messaging.suspend_identity_credential(credential.id, credential.revision)

{:ok, active} =
  MyApp.Messaging.activate_identity_credential(suspended.id, suspended.revision)

{:ok, revoked} =
  MyApp.Messaging.revoke_identity_credential(active.id, active.revision,
    reason: "controller request"
  )
```

Revocation is terminal. Each verification reads the current record. Evidence is
short-lived, but it is not a revocation-check mechanism or an authorization
result. Check a new proof for a later operation that requires current identity
assurance.

Rotation revokes the old credential and creates its replacement in one storage
operation. Rotation cannot change the issuer, subject, purpose, audience, or
rooms. It can change the provider and proof references, key version, validity,
and safe metadata:

```elixir
{:ok, %{revoked: old, credential: replacement}} =
  MyApp.Messaging.rotate_identity_credential(credential.id, credential.revision, %{
    provider_id: "my-identity-provider",
    proof_type: "ed25519-v2",
    proof_ref: "provider://agents/agent-123/keys/8",
    key_version_ref: "key-version-8",
    expires_at: DateTime.add(DateTime.utc_now(), 7_200, :second)
  })
```

ETS and SQLite implement the lifecycle and replay contracts. Other persistence
adapters can implement the optional identity callbacks in
`Jido.Messaging.Persistence`.

## Jidoka Integration Boundary

Jidoka is the first-party agent authoring and execution surface. A Jidoka-owned
adapter or a separate integration package can map a Jidoka agent to the subject
principal and consume `IdentityEvidence`.

Jido Messaging does not import a Jidoka agent specification, start a Jidoka
agent, or reproduce Jidoka runtime behavior. The core has no dependency on
Jidoka or `jido_harness`. Jido Messaging remains the authority for this
credential check. Jidoka remains the authority for agent authoring and
execution.

## Privacy Notes

A controller relation can correlate a person and an agent. Keep the audience
and room list as small as possible. Use opaque provider references. Do not put
names, keys, tokens, or proof payloads in credential metadata. Delete or revoke
credentials according to the host retention policy.
