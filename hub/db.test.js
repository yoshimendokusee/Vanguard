const test = require('node:test');
const assert = require('node:assert/strict');
const Database = require('better-sqlite3');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { openDb } = require('./db');

const legacySchema = `
  CREATE TABLE triage_reports (
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
  CREATE INDEX idx_reports_status ON triage_reports (status, triage);
`;

function temporaryDatabase(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-hub-db-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return path.join(directory, 'vanguard.db');
}

test('creates a fresh hub database from the initial migration and reopens it', (t) => {
  const file = temporaryDatabase(t);
  const db = openDb(file);
  assert.strictEqual(db.pragma('user_version', { simple: true }), 1);
  assert.deepStrictEqual(
    db.pragma('table_info(triage_reports)').map((column) => column.name),
    ['id', 'watch_id', 'location', 'injuries', 'triage', 'patient_count',
      'age_group', 'eta_minutes', 'raw_text', 'created_at', 'received_at', 'status'],
  );
  db.close();

  const reopened = openDb(file);
  assert.strictEqual(reopened.pragma('user_version', { simple: true }), 1);
  assert.strictEqual(
    reopened.prepare('SELECT COUNT(*) AS count FROM triage_reports').get().count,
    0,
  );
  reopened.close();
});

test('adopts a populated legacy database without changing reports or status', (t) => {
  const file = temporaryDatabase(t);
  const legacy = new Database(file);
  legacy.exec(legacySchema);
  legacy.prepare(`
    INSERT INTO triage_reports
      (watch_id, location, injuries, triage, patient_count, age_group,
       eta_minutes, raw_text, created_at, received_at, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    'W-TEST',
    'Barangay Arnaldo',
    'Drowning, Unconscious',
    'Immediate',
    2,
    'Child',
    10,
    'Synthetic legacy report',
    '2026-10-09T06:00:00.123Z',
    '2026-10-09T06:01:00.123Z',
    'arrived',
  );
  legacy.close();

  const db = openDb(file);
  assert.strictEqual(db.pragma('user_version', { simple: true }), 1);
  const rows = db.prepare('SELECT * FROM triage_reports').all();
  assert.strictEqual(rows.length, 1);
  assert.deepStrictEqual(
    {
      watch_id: rows[0].watch_id,
      location: rows[0].location,
      injuries: rows[0].injuries,
      triage: rows[0].triage,
      patient_count: rows[0].patient_count,
      age_group: rows[0].age_group,
      eta_minutes: rows[0].eta_minutes,
      raw_text: rows[0].raw_text,
      created_at: rows[0].created_at,
      received_at: rows[0].received_at,
      status: rows[0].status,
    },
    {
      watch_id: 'W-TEST',
      location: 'Barangay Arnaldo',
      injuries: 'Drowning, Unconscious',
      triage: 'Immediate',
      patient_count: 2,
      age_group: 'Child',
      eta_minutes: 10,
      raw_text: 'Synthetic legacy report',
      created_at: '2026-10-09T06:00:00.123Z',
      received_at: '2026-10-09T06:01:00.123Z',
      status: 'arrived',
    },
  );
  db.close();

  const reopened = openDb(file);
  assert.strictEqual(reopened.prepare('SELECT COUNT(*) AS count FROM triage_reports').get().count, 1);
  reopened.close();
});

test('refuses an incompatible legacy schema without advancing its version', (t) => {
  const file = temporaryDatabase(t);
  const legacy = new Database(file);
  legacy.exec(`
    CREATE TABLE triage_reports (id INTEGER PRIMARY KEY, status TEXT);
    INSERT INTO triage_reports (id, status) VALUES (7, 'arrived');
  `);
  legacy.close();

  assert.throws(() => openDb(file), /missing required columns/);

  const unchanged = new Database(file);
  assert.strictEqual(unchanged.pragma('user_version', { simple: true }), 0);
  assert.deepStrictEqual(unchanged.prepare('SELECT * FROM triage_reports').all(), [
    { id: 7, status: 'arrived' },
  ]);
  unchanged.close();
});

test('rolls back a failed initial migration without changing the existing schema', (t) => {
  const file = temporaryDatabase(t);
  const existing = new Database(file);
  existing.exec(`
    CREATE TABLE unrelated (status TEXT, triage TEXT);
    CREATE INDEX idx_reports_status ON unrelated (status, triage);
  `);
  existing.close();

  assert.throws(() => openDb(file), /did not create the expected idx_reports_status/);

  const unchanged = new Database(file);
  assert.strictEqual(unchanged.pragma('user_version', { simple: true }), 0);
  assert.strictEqual(
    unchanged.prepare(
      "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'triage_reports'",
    ).get().count,
    0,
  );
  assert.strictEqual(
    unchanged.prepare(
      "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'index' AND name = 'idx_reports_status'",
    ).get().count,
    1,
  );
  unchanged.close();
});
