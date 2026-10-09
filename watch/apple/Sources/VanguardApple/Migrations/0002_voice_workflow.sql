BEGIN IMMEDIATE;
-- Additive only: version-1 captures, transcriptions, extractions and receipts are untouched.

-- Corrected transcripts. The original stays in native_captures/native_transcriptions; each
-- correction is a new immutable version. `processing` is filled once, after the corrected
-- transcript has been re-extracted; `sent_at` once the hospital acknowledged the revision.
CREATE TABLE IF NOT EXISTS native_transcript_versions (
  capture_id TEXT NOT NULL REFERENCES native_captures(id),
  version INTEGER NOT NULL CHECK (version >= 1),
  transcript TEXT NOT NULL,
  reason TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  processing TEXT,
  sent_at TEXT,
  PRIMARY KEY (capture_id, version));
CREATE TRIGGER IF NOT EXISTS native_version_immutable BEFORE UPDATE ON native_transcript_versions
  WHEN OLD.capture_id != NEW.capture_id OR OLD.version != NEW.version OR OLD.transcript != NEW.transcript
    OR OLD.reason != NEW.reason OR OLD.request_id != NEW.request_id OR OLD.created_at != NEW.created_at
    OR (OLD.processing IS NOT NULL AND (NEW.processing IS NULL OR OLD.processing != NEW.processing))
    OR (OLD.sent_at IS NOT NULL AND (NEW.sent_at IS NULL OR OLD.sent_at != NEW.sent_at))
  BEGIN SELECT RAISE(ABORT, 'immutable transcript version'); END;
CREATE TRIGGER IF NOT EXISTS native_version_no_delete BEFORE DELETE ON native_transcript_versions
  BEGIN SELECT RAISE(ABORT, 'immutable transcript version'); END;

-- Structured report details (location, patients, age group, ETA). Append-only revisions.
CREATE TABLE IF NOT EXISTS native_report_revisions (
  capture_id TEXT NOT NULL REFERENCES native_captures(id),
  revision INTEGER NOT NULL CHECK (revision >= 1),
  source TEXT NOT NULL CHECK (source IN ('extracted', 'edited')),
  details TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (capture_id, revision));
CREATE TRIGGER IF NOT EXISTS native_report_revision_no_update BEFORE UPDATE ON native_report_revisions
  BEGIN SELECT RAISE(ABORT, 'immutable report revision'); END;
CREATE TRIGGER IF NOT EXISTS native_report_revision_no_delete BEFORE DELETE ON native_report_revisions
  BEGIN SELECT RAISE(ABORT, 'immutable report revision'); END;

-- Delivery is the only mutable table: it records transport state, never clinical content.
-- DELIVERED requires a hospital receipt in native_receipts (checked by the application).
CREATE TABLE IF NOT EXISTS native_delivery (
  capture_id TEXT PRIMARY KEY REFERENCES native_captures(id),
  state TEXT NOT NULL CHECK (state IN ('LOCAL_SAVED', 'QUEUED', 'TRANSFERRING', 'AWAITING_RECEIPT',
    'DELIVERED', 'RETRY_REQUIRED', 'FAILED_PERMANENTLY')),
  held INTEGER NOT NULL DEFAULT 0 CHECK (held IN (0, 1)),
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  encounter_id TEXT NOT NULL,
  updated_at TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS native_delivery_no_delete BEFORE DELETE ON native_delivery
  BEGIN SELECT RAISE(ABORT, 'delivery state is retained'); END;
CREATE TRIGGER IF NOT EXISTS native_delivery_identity BEFORE UPDATE ON native_delivery
  WHEN OLD.capture_id != NEW.capture_id OR OLD.encounter_id != NEW.encounter_id
  BEGIN SELECT RAISE(ABORT, 'delivery identity is immutable'); END;
-- A delivered report can never move back: a hospital receipt is final for that report.
CREATE TRIGGER IF NOT EXISTS native_delivery_final BEFORE UPDATE ON native_delivery
  WHEN OLD.state = 'DELIVERED' AND NEW.state != 'DELIVERED'
  BEGIN SELECT RAISE(ABORT, 'delivered report cannot be undelivered'); END;
PRAGMA user_version=2;
COMMIT;
