const Database = require('better-sqlite3');
const fs = require('fs');
const path = require('path');

function openDb(file = process.env.DB_PATH || path.join(__dirname, 'data', 'vanguard.db')) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS triage_reports (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      watch_id      TEXT NOT NULL,
      location      TEXT NOT NULL,   -- pickup point
      injuries      TEXT NOT NULL,   -- comma-separated findings, e.g. "Drowning, Unconscious"
      triage        TEXT NOT NULL CHECK (triage IN ('Immediate','Unassessed','Delayed','Minor','Deceased')),
      patient_count INTEGER NOT NULL DEFAULT 1 CHECK (patient_count BETWEEN 1 AND 99),
      age_group     TEXT NOT NULL DEFAULT 'Unspecified',
      eta_minutes   INTEGER,         -- minutes after created_at; NULL = not stated
      raw_text      TEXT NOT NULL DEFAULT '',
      created_at    TEXT NOT NULL,   -- when the rescuer spoke (watch clock, ISO UTC)
      received_at   TEXT NOT NULL,   -- when the hub got it (hub clock, ISO UTC)
      status        TEXT NOT NULL DEFAULT 'inbound' CHECK (status IN ('inbound','arrived','cancelled')),
      -- Conflict resolution: the same watch can never produce two reports with
      -- the same timestamp, so a re-synced batch collides here and is ignored.
      UNIQUE (watch_id, created_at)
    );
    CREATE INDEX IF NOT EXISTS idx_reports_status ON triage_reports (status, triage);
  `);
  return db;
}

module.exports = { openDb };
