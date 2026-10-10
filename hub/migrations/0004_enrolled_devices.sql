-- Device credentials issued by one-time operator enrollment codes.
-- Tokens are stored as SHA-256 digests; plaintext is returned only once.
CREATE TABLE enrolled_devices (
  id TEXT PRIMARY KEY,
  watch_id TEXT NOT NULL UNIQUE,
  token_digest TEXT NOT NULL UNIQUE CHECK (length(token_digest) = 64),
  created_at TEXT NOT NULL
);

CREATE INDEX idx_enrolled_devices_watch_id ON enrolled_devices (watch_id);
