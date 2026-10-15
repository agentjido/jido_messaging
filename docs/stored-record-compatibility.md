# Stored-record compatibility

## Current format: v1

Format v1 is the existing Erlang external term for the complete record.
It has no wrapper and no version field inside the payload. The name v1 is the
documented compatibility contract for this format. It does not add a database
version or a new write format.

SQLite stores the binary as a BLOB. PostgreSQL stores it as BYTEA. The namespace,
record kind, record ID, and query index columns remain separate from the payload.
ETS stores the record term directly and has no durable restart guarantee.

`Persistence.Payload.encode/1` uses the existing `term_to_binary/1` call.
SQLite retains its existing decoder options. PostgreSQL retains `[:safe]`.
The stores are trusted application storage. This codec is not a transport
decoder for untrusted input. C4 adds no migration or payload rewrite.

## Compatibility rules

1. Keep persisted record module names and fields stable. An Erlang struct stores
   its module atom and field map. A source path change does not rename that atom.
2. Keep enum atoms, nested record shapes, IDs, revisions, and timestamp meaning
   stable. Do not rebuild old records with constructors on each read.
3. Keep namespace and query index formats stable. Index changes require a
   migration that preserves payload bytes and message ID cursors.
4. Preserve metadata and fields that a reader does not use. Do not drop them
   during a read and write cycle.
5. Do not infer a payload version from a package version, source path, or table
   migration number. Index migrations and record migrations are separate.

The fixed fixture `test/fixtures/stored_records_v1.json` was saved from commit
`3022c269e4e3faca25a13ecaff37884138bb76c0`, before C4. It records all 23 persisted
struct module names, fields, and sample payload bytes. Eight core record samples
use their public constructors. The other samples check stored term shapes; they
do not claim to be valid domain commands.

Tests read every old sample and preserve its field set and values through a
write and read cycle. Equal Erlang maps can have a different encoded entry order
in another VM. Re-encoded byte equality is not part of the v1 contract. Reads
must leave the stored payload bytes unchanged.
SQLite and PostgreSQL tests insert old core payloads directly, close the store,
reopen the same namespace, and read through public adapter functions. They check
unchanged bytes, message order, and cursor behavior. The aggregate's 93 callback
signatures and optional callback list use the same fixed fixture.

This fixture proves compatibility with the pre-C4 code. It does not prove
compatibility with an unknown historical record format.

## Contract for a future format change

Before a stored field or module changes, define a new format and an explicit
upgrade function. Keep the v1 decoder available. Detect a future envelope by an
explicit format marker. Reject unknown versions with a stable error. Do not
guess the format from missing fields or silently accept an unknown version.

An upgrade must be pure and deterministic. It must preserve identity, namespace,
revisions, timestamps, metadata, and fields that have no approved removal rule.
It must not create authority, reactivate a revoked record, or run a current
constructor that supplies new random IDs or clock values.

Add fixed old and new payload fixtures. Test reopen, index queries, exact
revisions, terminal revocation, and rollback on a failed upgrade. Test every
supported backend. Define the minimum reader version and the rollback boundary
before new-format writes begin. A mixed-version deployment needs an explicit
read and write policy.

C4 does not need an upgrade function because no stored shape changes.
