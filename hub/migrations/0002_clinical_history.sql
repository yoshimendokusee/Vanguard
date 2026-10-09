CREATE TABLE patients (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);
CREATE TABLE patient_revisions (
  patient_id TEXT NOT NULL REFERENCES patients(id),
  revision INTEGER NOT NULL CHECK (revision >= 0),
  request_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  reason TEXT NOT NULL,
  identity_status TEXT NOT NULL CHECK (identity_status IN ('unknown', 'reported')),
  name TEXT,
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  created_at TEXT NOT NULL,
  PRIMARY KEY (patient_id, revision),
  UNIQUE (patient_id, request_id),
  CHECK (identity_status != 'unknown' OR name IS NULL)
);
CREATE TABLE encounters (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);
CREATE TABLE encounter_revisions (
  encounter_id TEXT NOT NULL REFERENCES encounters(id),
  revision INTEGER NOT NULL CHECK (revision >= 0),
  request_id TEXT NOT NULL,
  actor TEXT NOT NULL,
  reason TEXT NOT NULL,
  patient_id TEXT REFERENCES patients(id),
  incident TEXT,
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  created_at TEXT NOT NULL,
  PRIMARY KEY (encounter_id, revision),
  UNIQUE (encounter_id, request_id)
);
CREATE INDEX idx_encounter_patient ON encounter_revisions(patient_id);
CREATE TABLE report_evidence (
  report_id INTEGER PRIMARY KEY REFERENCES triage_reports(id),
  encounter_id TEXT NOT NULL REFERENCES encounters(id),
  source_report_id TEXT UNIQUE,
  patient_count_known INTEGER NOT NULL CHECK (patient_count_known IN (0, 1)),
  processing_json TEXT CHECK (processing_json IS NULL OR json_valid(processing_json)),
  submitted_json TEXT NOT NULL CHECK (json_valid(submitted_json))
);
CREATE INDEX idx_report_encounter ON report_evidence(encounter_id);
CREATE TABLE report_revisions (
  report_id INTEGER NOT NULL REFERENCES triage_reports(id),
  revision INTEGER NOT NULL CHECK (revision >= 0),
  request_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('intake', 'correction', 'extraction', 'override')),
  actor TEXT NOT NULL,
  reason TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  state_json TEXT NOT NULL CHECK (json_valid(state_json)),
  assessment_json TEXT NOT NULL CHECK (json_valid(assessment_json)),
  created_at TEXT NOT NULL,
  PRIMARY KEY (report_id, revision),
  UNIQUE (report_id, request_id)
);
CREATE TABLE report_events (
  id INTEGER PRIMARY KEY,
  report_id INTEGER NOT NULL REFERENCES triage_reports(id),
  event TEXT NOT NULL CHECK (event IN ('received', 'status')),
  detail TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_report_events ON report_events(report_id, id);

CREATE TRIGGER patient_revisions_no_update BEFORE UPDATE ON patient_revisions
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER patient_revisions_no_delete BEFORE DELETE ON patient_revisions
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER encounter_revisions_no_update BEFORE UPDATE ON encounter_revisions
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER encounter_revisions_no_delete BEFORE DELETE ON encounter_revisions
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER report_evidence_no_update BEFORE UPDATE ON report_evidence
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER report_evidence_no_delete BEFORE DELETE ON report_evidence
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER report_revisions_no_update BEFORE UPDATE ON report_revisions
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER report_revisions_no_delete BEFORE DELETE ON report_revisions
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER report_events_no_update BEFORE UPDATE ON report_events
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER report_events_no_delete BEFORE DELETE ON report_events
BEGIN SELECT RAISE(ABORT, 'Clinical history is immutable'); END;

CREATE TRIGGER triage_reports_preserve_source BEFORE UPDATE ON triage_reports
WHEN NEW.watch_id IS NOT OLD.watch_id OR NEW.location IS NOT OLD.location
  OR NEW.injuries IS NOT OLD.injuries OR NEW.triage IS NOT OLD.triage
  OR NEW.patient_count IS NOT OLD.patient_count OR NEW.age_group IS NOT OLD.age_group
  OR NEW.eta_minutes IS NOT OLD.eta_minutes OR NEW.raw_text IS NOT OLD.raw_text
  OR NEW.created_at IS NOT OLD.created_at OR NEW.received_at IS NOT OLD.received_at
BEGIN SELECT RAISE(ABORT, 'Original report is immutable'); END;
