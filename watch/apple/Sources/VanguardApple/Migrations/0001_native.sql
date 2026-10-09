BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS native_captures (
  local_id INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, watch_id TEXT NOT NULL,
  created_at TEXT NOT NULL, transcript TEXT, audio_path TEXT,
  UNIQUE(watch_id, created_at));
CREATE TABLE IF NOT EXISTS native_transcriptions (
  capture_id TEXT PRIMARY KEY REFERENCES native_captures(id), transcript TEXT NOT NULL, engine TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS native_extractions (
  capture_id TEXT PRIMARY KEY REFERENCES native_captures(id), transcript TEXT NOT NULL, processing TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS native_receipts (
  capture_id TEXT PRIMARY KEY REFERENCES native_captures(id), acknowledged_at TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS native_speech_no_update BEFORE UPDATE ON native_transcriptions BEGIN SELECT RAISE(ABORT, 'immutable transcription'); END;
CREATE TRIGGER IF NOT EXISTS native_speech_no_delete BEFORE DELETE ON native_transcriptions BEGIN SELECT RAISE(ABORT, 'immutable transcription'); END;
CREATE TRIGGER IF NOT EXISTS native_original_no_update BEFORE UPDATE ON native_captures BEGIN SELECT RAISE(ABORT, 'immutable capture'); END;
CREATE TRIGGER IF NOT EXISTS native_original_no_delete BEFORE DELETE ON native_captures BEGIN SELECT RAISE(ABORT, 'immutable capture'); END;
CREATE TRIGGER IF NOT EXISTS native_extraction_no_update BEFORE UPDATE ON native_extractions BEGIN SELECT RAISE(ABORT, 'immutable extraction'); END;
CREATE TRIGGER IF NOT EXISTS native_extraction_no_delete BEFORE DELETE ON native_extractions BEGIN SELECT RAISE(ABORT, 'immutable extraction'); END;
PRAGMA user_version=1;
COMMIT;
