UPDATE jido_messaging_records
SET inserted_at = to_char(
  inserted_at::timestamptz AT TIME ZONE 'UTC',
  'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
)
WHERE kind = 'message' AND inserted_at IS NOT NULL;
