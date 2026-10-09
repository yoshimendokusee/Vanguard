const test = require('node:test');
const assert = require('node:assert/strict');
const Database = require('better-sqlite3');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { openDb } = require('./db');
const { ingestBatch } = require('./sync');
const { reportView } = require('./clinical');
const { Worker } = require('node:worker_threads');
const { once } = require('node:events');

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
  assert.strictEqual(db.pragma('user_version', { simple: true }), 3);
  assert.deepStrictEqual(
    db.pragma('table_info(triage_reports)').map((column) => column.name),
    ['id', 'watch_id', 'location', 'injuries', 'triage', 'patient_count',
      'age_group', 'eta_minutes', 'raw_text', 'created_at', 'received_at', 'status'],
  );
  db.close();

  const reopened = openDb(file);
  assert.strictEqual(reopened.pragma('user_version', { simple: true }), 3);
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
  assert.strictEqual(db.pragma('user_version', { simple: true }), 3);
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

test('upgrades populated version 1 and retains the initial assessment and encounter after restart', (t) => {
  const file = temporaryDatabase(t);
  const legacy = new Database(file);
  legacy.exec(legacySchema);
  legacy.pragma('user_version = 1');
  legacy.prepare(`INSERT INTO triage_reports (watch_id, location, injuries, triage, raw_text, created_at, received_at, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run('W-UPGRADE', 'Synthetic pickup', 'Severe bleeding', 'Minor',
    '  Synthetic original  ', '2026-10-09T00:00:00.000Z', '2026-10-09T00:01:00.000Z', 'arrived');
  const before = legacy.prepare('SELECT * FROM triage_reports').all();
  legacy.close();
  let db = openDb(file);
  assert.deepEqual(db.prepare('SELECT * FROM triage_reports').all(), before);
  const initial = reportView(db, before[0].id, true);
  assert.equal(initial.effective_triage, 'Immediate');
  assert.equal(initial.history[0].state.transcript, '  Synthetic original  ');
  assert.equal(initial.history[0].actor, 'migration');
  assert.ok(initial.history[0].created_at > initial.received_at, 'Backfill must not invent a historical assessment time');
  assert.equal(initial.patient_count_known, false, 'Legacy defaults are not evidence of a reported count');
  assert.equal(db.pragma('foreign_key_check').length, 0);
  db.close();
  db = openDb(file);
  assert.deepEqual(reportView(db, before[0].id, true), initial);
  const replay = ingestBatch(db, 'W-UPGRADE', [{ localId: 1, location: 'Synthetic pickup', injuries: 'Severe bleeding',
    triage: 'Minor', rawText: '  Synthetic original  ', createdAt: '2026-10-09T00:00:00.000Z' }]);
  assert.deepEqual(replay.ackLocalIds, [1]);
  db.close();
});

test('version 2 migration failure rolls back and preserves a populated version 1 database', (t) => {
  const file = temporaryDatabase(t);
  const legacy = new Database(file);
  legacy.exec(legacySchema);
  legacy.exec('CREATE TABLE patients (existing TEXT);');
  legacy.pragma('user_version = 1');
  legacy.prepare(`INSERT INTO triage_reports (watch_id, location, injuries, triage, created_at, received_at)
    VALUES ('W-SYNTHETIC', 'Synthetic pickup', 'Unspecified', 'Unassessed', '2026-10-09T00:00:00.000Z', '2026-10-09T00:00:00.000Z')`).run();
  const before = legacy.prepare('SELECT * FROM triage_reports').all();
  legacy.close();
  assert.throws(() => openDb(file), /already exists/);
  const unchanged = new Database(file);
  assert.equal(unchanged.pragma('user_version', { simple: true }), 1);
  assert.deepEqual(unchanged.prepare('SELECT * FROM triage_reports').all(), before);
  assert.equal(unchanged.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'report_evidence'").get().n, 0);
  unchanged.close();
});

function populatedVersion2(t, extraSql = '') {
  const file = temporaryDatabase(t);
  const db = openDb(file);
  ingestBatch(db, 'W-V2', [{ localId: 1, location: 'Synthetic pickup', injuries: 'Severe bleeding',
    triage: 'Immediate', rawText: 'Synthetic v2 report', createdAt: '2026-10-09T00:00:00.000Z' }]);
  db.prepare("UPDATE triage_reports SET status = 'arrived'").run();
  db.close();
  // Synthetic stand-in for a database written by the v2 binary.
  const v2 = new Database(file);
  v2.exec(`DROP TABLE cloud_sync; ${extraSql}`);
  v2.pragma('user_version = 2');
  const before = {
    reports: v2.prepare('SELECT * FROM triage_reports').all(),
    revisions: v2.prepare('SELECT * FROM report_revisions').all(),
    events: v2.prepare('SELECT * FROM report_events').all(),
  };
  v2.close();
  return { file, before };
}

test('upgrades populated version 2 to cloud sync state without changing reports or history', (t) => {
  const { file, before } = populatedVersion2(t);
  let db = openDb(file);
  assert.equal(db.pragma('user_version', { simple: true }), 3);
  assert.deepEqual(db.prepare('SELECT * FROM triage_reports').all(), before.reports);
  assert.deepEqual(db.prepare('SELECT * FROM report_revisions').all(), before.revisions);
  assert.deepEqual(db.prepare('SELECT * FROM report_events').all(), before.events);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM cloud_sync').get().n, 0, 'Nothing is marked as uploaded by the upgrade');
  db.close();
  db = openDb(file);
  assert.deepEqual(db.prepare('SELECT * FROM triage_reports').all(), before.reports);
  assert.deepEqual(ingestBatch(db, 'W-V2', [{ localId: 1, location: 'Synthetic pickup', injuries: 'Severe bleeding',
    triage: 'Immediate', rawText: 'Synthetic v2 report', createdAt: '2026-10-09T00:00:00.000Z' }]).ackLocalIds, [1]);
  db.close();
});

test('version 3 migration failure rolls back and preserves a populated version 2 database', (t) => {
  const { file, before } = populatedVersion2(t, 'CREATE TABLE cloud_sync (existing TEXT);');
  assert.throws(() => openDb(file), /already exists/);
  const unchanged = new Database(file);
  assert.equal(unchanged.pragma('user_version', { simple: true }), 2);
  assert.deepEqual(unchanged.prepare('SELECT * FROM triage_reports').all(), before.reports);
  assert.equal(unchanged.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE name = 'idx_cloud_sync_pending'").get().n, 0);
  unchanged.close();
});

test('another writer waits for an atomic commit and safely acknowledges the committed replay', async (t) => {
  const file = temporaryDatabase(t);
  const db = openDb(file);
  t.after(() => db.close());
  const report = { localId: 1, location: 'Synthetic pickup', injuries: 'Unspecified', triage: 'Unassessed', createdAt: '2026-10-09T00:00:00Z' };
  db.exec('BEGIN IMMEDIATE');
  ingestBatch(db, 'W-CONCURRENT', [report]);
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const { openDb } = require(workerData.dbModule);
    const { ingestBatch } = require(workerData.syncModule);
    parentPort.postMessage('ready');
    parentPort.once('message', () => {
      parentPort.postMessage('attempting');
      const db = openDb(workerData.file);
      const result = ingestBatch(db, 'W-CONCURRENT', [workerData.report]);
      db.close();
      parentPort.postMessage({ inserted: result.inserted.length, duplicates: result.duplicates, ack: result.ackLocalIds });
    });
  `, { eval: true, workerData: { file, report, dbModule: require.resolve('./db'), syncModule: require.resolve('./sync') } });
  t.after(() => worker.terminate());
  assert.equal((await once(worker, 'message'))[0], 'ready');
  const attempting = once(worker, 'message');
  worker.postMessage('go');
  assert.equal((await attempting)[0], 'attempting');
  const done = once(worker, 'message');
  await new Promise((resolve) => setTimeout(resolve, 50));
  db.exec('COMMIT');
  assert.deepEqual((await done)[0], { inserted: 0, duplicates: 1, ack: [1] });
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM report_revisions').get().n, 1);
});
