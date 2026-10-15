# Messaging workflow boundaries

Application code should use the generated instance API. Use `execute/2` for
authorized typed commands and `accept_delivery/1` for provider deliveries.
Use `Ingest.ingest_incoming/5` when the application already has normalized
incoming data and must supply ingest policy options.

Record functions such as `save_message/1` read or write canonical records.
They do not apply the typed-command or ingest workflow. Operator functions
such as `register_agent/3` and `create_bridge_room/1` manage runtime assignment
and routing setup.

## Entry-module owners

The entry module and generated instance keep their existing public function
names, arguments, guards, defaults, and return values. The instance macro
continues to provide the same functions and runtime names.

| Internal owner | Responsibility |
| --- | --- |
| `Jido.Messaging.Agents.Assignment` | Agent registration, thread assignment, runner recovery, and rollback |
| `Jido.Messaging.Routing.BridgeRoom` | Room setup, bridge configuration, bindings, and routing policy |
| `Jido.Messaging.History.Transcript` | Scoped canonical history and optional search projection operations |

The public functions forward to these owners. Assignment and room setup use
the existing low-level record functions. Storage formats, storage callback
groups, supervisor structure, and provider-call mechanics remain unchanged.

## Ingest stages

| Stage | Work |
| --- | --- |
| Prepare | Verify the sender; resolve the room, participant, authorship, and existing thread; build context and message content |
| Policy | Apply mention and command-prefix rules, gating, and moderation |
| Commit | Save the prepared canonical message and resolve an uncertain write by reading the same message ID |
| Publish | Complete automatic thread work, update session routes, restore runners, update room views, and emit the received fact |

`Ingest.Policy` owns message policy. `Ingest.ThreadScope` owns thread resolution,
automatic thread work, and thread context. `Ingest.Prepared` carries typed,
transient data between stages. It is not a stored record. Only its canonical
message enters the message write.

The stage order remains unchanged. An existing thread can be resolved and
assigned during preparation. Automatic provider thread creation starts after
the canonical message is committed. A later thread-link update uses the same
message ID.

## Commit and retry rules

Before commit, a policy denial has no canonical message write. The duplicate
claim is released so that a later allowed attempt can proceed.

A store can fail after it writes. Ingest reads the same prepared message ID:

- If the record exists, the message is accepted.
- If the record is absent, an acceptance failure is returned.
- If the read cannot establish the outcome, Ingest returns
  `request_outcome_unknown` and retains the duplicate claim.

Ingest does not build a second canonical message to recover that write.
After acceptance, protected observation failures emit an observation failure
and keep the successful acceptance result. Automatic thread failures retain
the accepted message. Within the existing duplicate-claim lifetime, a duplicate
delivery does not repeat the accepted write.

Assignment keeps its existing order of persistence, room-state changes, and
runner startup or shutdown. It retains the existing rollback and rollback-error
results. Room setup retains its existing validation, idempotency, conflict
results, and partial-write behavior.
