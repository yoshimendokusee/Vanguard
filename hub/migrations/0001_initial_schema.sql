CREATE TABLE IF NOT EXISTS triage_reports (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  watch_id      TEXT NOT NULL,
  location      TEXT NOT NULL,
  injuries      TEXT NOT NULL,
  triage        TEXT NOT NULL CHECK (
    triage IN ('Immediate', 'Unassessed', 'Delayed', 'Minor', 'Deceased')
  ),
  patient_count INTEGER NOT NULL DEFAULT 1 CHECK (patient_count BETWEEN 1 AND 99),
  age_group     TEXT NOT NULL DEFAULT 'Unspecified',
  eta_minutes   INTEGER,
  raw_text      TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL,
  received_at   TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'inbound'
                CHECK (status IN ('inbound', 'arrived', 'cancelled')),
  UNIQUE (watch_id, created_at)
);

CREATE INDEX IF NOT EXISTS idx_reports_status
  ON triage_reports (status, triage);
