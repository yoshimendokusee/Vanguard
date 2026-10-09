-- Hub -> Supabase backup state, separate from LAN receipt and clinical history.
-- A report is queued once with a UUID that every retry reuses, so cloud upserts
-- stay idempotent. Only an upsert response naming that UUID sets synced_at.
CREATE TABLE cloud_sync (
  report_id INTEGER PRIMARY KEY REFERENCES triage_reports(id),
  cloud_report_id TEXT NOT NULL UNIQUE CHECK (length(cloud_report_id) = 36),
  queued_at TEXT NOT NULL,
  synced_at TEXT,
  owner_id TEXT,
  rejected_reason TEXT,
  CHECK (synced_at IS NULL OR owner_id IS NOT NULL)
);
CREATE INDEX idx_cloud_sync_pending ON cloud_sync (synced_at, rejected_reason);
