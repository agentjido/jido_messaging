# Signal contract fixtures

These fixtures record the compiled public contracts at commit
`57a7608805f721ecc05de953d78af0a6ed235a57`, before checkpoint C2.

`signal_contracts_v1.json` records all 65 public Signal types, schema URNs,
kinds, function exports, and schema hashes. The shared export list applies to
every Signal. Hashes use `Zoi.to_json_schema/1`. Object keys are sorted recursively
and stored as `{:object, pairs}`. Array order is retained. The hash is SHA-256
of `:erlang.term_to_binary/1` for this normalized value.

`operation_contracts_v1.json` records all 36 request mappings and one accepted
payload for each of the 56 completed-result variants. These payloads came from
the compiled baseline schemas. They do not come from the new schema builders.

Keep these fixtures fixed during refactors. Change them only when a separate
public contract change is approved. The contract test also checks nested field
rejection, required nullable cursors, operation-specific resource kinds, and
the different status and failure-code sets.
