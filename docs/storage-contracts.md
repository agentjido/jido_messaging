# Storage feature contracts

The public `Jido.Messaging.Persistence` behaviour retains its 93 callback
signatures and its optional callback list. Existing custom adapters can continue
to use it. No entry function, return value, or runtime feature fallback changes.

Built-in adapters now declare smaller behaviours under
`Jido.Messaging.Persistence.Contracts`. Each declared group requires all its
callbacks. A group has no optional callbacks. A callback that returns
`{:error, :unsupported}` does not satisfy the functional contract for a declared
group.

| Contract | Callbacks | ETS | SQLite | PostgreSQL |
| --- | ---: | --- | --- | --- |
| Lifecycle | 3 | Yes | Yes | Yes |
| Transactions and connection release | 2 | No | Yes | Yes |
| Records, history, directory, onboarding | 22 | Yes | Yes | Yes |
| Provider bindings | 11 | Yes | Yes | Yes |
| Bridge and routing control plane | 10 | Yes | Yes | Yes |
| Principal and authorization records | 13 | Yes | Yes | Yes |
| External identity lifecycle | 4 | Yes | Yes | No |
| Agent endpoints, room membership, thread routes | 11 | Yes | Yes | No |
| Agent directory projections | 3 | Yes | Yes | No |
| Credentials, rotation, assertion replay | 5 | Yes | Yes | No |
| Delegation and continuity | 4 | Yes | Yes | No |
| Trust evidence | 2 | Yes | Yes | No |
| Activity projections | 3 | Yes | Yes | No |
| Total | 93 | 91 | 93 | 61 |

ETS retains its existing API. It does not add `transaction/2` or `close/1`.
PostgreSQL retains its seven unsupported optional groups. C4 adds no storage
feature support.

## Contract ownership

The feature behaviours own the contracts for new adapter work. The aggregate
behaviour is the compatibility surface for existing custom adapters. Native
callback declarations remain explicit in both surfaces. The contract tests
require the feature groups to partition the 93 aggregate callbacks exactly and
to retain every signature. This avoids a generated callback DSL and detects
changes between the two surfaces.

`Contracts.declared/1` reads the adapter's behaviour declarations.
`Contracts.missing_callbacks/2` checks a complete feature group. The reusable
`Persistence.Conformance` suite checks each declaration before its functional
tests. Fixed tests also check the exact support matrix above.

## Pure rules and adapter work

`Persistence.RecordRules` owns immutable authorization identity, exact revision
transitions, terminal credential revocation, directory and activity revision
rules, cursor option validation, and the existing SQL index value formats.
It receives stored records as values. It performs no storage call, lock,
transaction, process operation, or clock read.

Each adapter owns reads, writes, indexes, cursor lookup in the requested scope,
SQL predicates, compare-and-swap operations, locks, transactions, cleanup, and
connections. The shared rules do not move a read outside an existing lock or
transaction. The adapters retain their existing error handling for failed reads.

`Persistence.Payload` provides the existing Erlang term encoder and decoder.
See [Stored-record compatibility](stored-record-compatibility.md).

## Required checks

The same tests run on each adapter that claims the feature. These tests use real
storage and assert conflicts, revisions, revocation, cleanup, ordering, scope,
and concurrent writes where the feature permits them.

| Feature | Functional tests |
| --- | --- |
| Lifecycle, records, provider bindings, control plane | `persistence/conformance_test.exs`, `storage_boundary_regression_test.exs`, `directory_query_ownership_test.exs`, `message_query_limit_scope_test.exs`, `sqlite_transaction_composition_test.exs`, `postgres_test.exs` |
| Principal and authorization records | `principal_projection_ownership_test.exs`, `authorization_revision_ownership_test.exs`, `room_authority_cleanup_test.exs`, `postgres_authorization_test.exs`, `authorization_test.exs` |
| External identity lifecycle | `checkpoint_storage_contract_test.exs`, `identity_test.exs` |
| Agent routing | `agent_record_ownership_test.exs`, `agent_endpoints_test.exs` |
| Agent directory projections | `directory_revision_scope_test.exs`, `agent_directory_test.exs` |
| Credentials and assertion replay | `credential_rotation_ownership_test.exs`, `credential_cleanup_scope_test.exs`, `identity_credentials_test.exs` |
| Delegation and continuity | `delegation_transport_test.exs`, `continuity_test.exs` |
| Trust evidence | `advisory_evidence_scope_test.exs`, `trust_evidence_test.exs` |
| Activity projections | `activity_scope_cleanup_test.exs`, `messaging_activity_projection_test.exs` |

The ownership, scope, cleanup, regression, and adapter test files listed above
are in `test/jido_messaging/persistence`. The other domain test files are in
`test/jido_messaging`. The contract matrix and stored-record tests are in
`persistence/feature_contract_test.exs` and
`persistence/stored_record_compatibility_test.exs`.
