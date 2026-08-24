-- jido-messaging-statement
CREATE TABLE IF NOT EXISTS jido_messaging_records (
  instance_id TEXT NOT NULL CHECK (instance_id <> ''),
  kind TEXT NOT NULL,
  id TEXT NOT NULL,
  room_id TEXT,
  thread_id TEXT,
  sender_id TEXT,
  inserted_at TEXT,
  channel TEXT,
  bridge_id TEXT,
  external_id TEXT,
  payload BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (instance_id, kind, id)
)

-- jido-messaging-statement
CREATE INDEX IF NOT EXISTS jido_messaging_records_room_idx
  ON jido_messaging_records (instance_id, kind, room_id)

-- jido-messaging-statement
CREATE INDEX IF NOT EXISTS jido_messaging_records_thread_idx
  ON jido_messaging_records (instance_id, kind, thread_id)

-- jido-messaging-statement
CREATE INDEX IF NOT EXISTS jido_messaging_records_external_idx
  ON jido_messaging_records (instance_id, kind, channel, bridge_id, external_id)

-- jido-messaging-statement
CREATE INDEX IF NOT EXISTS jido_messaging_records_message_page_idx
  ON jido_messaging_records (
    instance_id,
    kind,
    room_id,
    thread_id,
    (COALESCE(inserted_at, '')),
    id
  )

-- jido-messaging-statement
CREATE INDEX IF NOT EXISTS jido_messaging_records_participant_history_idx
  ON jido_messaging_records (
    instance_id,
    kind,
    sender_id,
    (COALESCE(inserted_at, '')),
    id
  )

-- jido-messaging-statement
CREATE UNIQUE INDEX IF NOT EXISTS jido_messaging_records_room_binding_unique_idx
  ON jido_messaging_records (instance_id, channel, bridge_id, external_id)
  WHERE kind = 'room_binding'

-- jido-messaging-statement
CREATE UNIQUE INDEX IF NOT EXISTS jido_messaging_records_participant_binding_unique_idx
  ON jido_messaging_records (instance_id, channel, bridge_id, external_id)
  WHERE kind = 'participant_binding'
