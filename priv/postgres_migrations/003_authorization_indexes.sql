CREATE UNIQUE INDEX IF NOT EXISTS jido_messaging_records_membership_unique_idx
  ON jido_messaging_records (instance_id, room_id, sender_id)
  WHERE kind = 'membership';

-- jido-messaging-statement

CREATE UNIQUE INDEX IF NOT EXISTS jido_messaging_records_invocation_policy_unique_idx
  ON jido_messaging_records (instance_id, sender_id, external_id)
  WHERE kind = 'invocation_policy';

-- jido-messaging-statement

CREATE INDEX IF NOT EXISTS jido_messaging_records_authorization_principal_idx
  ON jido_messaging_records (instance_id, kind, sender_id, inserted_at, id)
  WHERE kind IN ('membership', 'principal_grant', 'invocation_policy');
