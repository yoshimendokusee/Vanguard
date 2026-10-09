const Database = require('better-sqlite3');
const fs = require('fs');
const path = require('path');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');
const REPORT_COLUMNS = [
  'id',
  'watch_id',
  'location',
  'injuries',
  'triage',
  'patient_count',
  'age_group',
  'eta_minutes',
  'raw_text',
  'created_at',
  'received_at',
  'status',
];

function loadMigrations() {
  const migrations = fs.readdirSync(MIGRATIONS_DIR)
    .filter((file) => /^\d{4}_[a-z0-9_]+\.sql$/.test(file))
    .map((file) => ({
      version: Number(file.slice(0, 4)),
      file,
      sql: fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8'),
    }))
    .sort((a, b) => a.version - b.version);

  migrations.forEach((migration, index) => {
    if (migration.version !== index + 1) {
      throw new Error(`Hub migrations must be sequential from 0001; found ${migration.file}`);
    }
  });
  if (migrations.length === 0) {
    throw new Error(`No hub database migrations found in ${MIGRATIONS_DIR}`);
  }
  return migrations;
}

function hasTable(db, name) {
  return Boolean(db.prepare(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
  ).get(name));
}

function hasUniqueReportIdentity(db) {
  const indexes = db.pragma('index_list(triage_reports)');
  return indexes
    .filter((index) => index.unique === 1)
    .some((index) => {
      const quotedName = `"${index.name.replaceAll('"', '""')}"`;
      const columns = db.pragma(`index_info(${quotedName})`)
        .sort((a, b) => a.seqno - b.seqno)
        .map((column) => column.name);
      return columns.join(',') === 'watch_id,created_at';
    });
}

function hasStatusIndex(db) {
  const index = db.pragma('index_list(triage_reports)')
    .find((entry) => entry.name === 'idx_reports_status');
  if (!index) return false;
  const quotedName = `"${index.name.replaceAll('"', '""')}"`;
  const columns = db.pragma(`index_info(${quotedName})`)
    .sort((a, b) => a.seqno - b.seqno)
    .map((column) => column.name);
  return columns.join(',') === 'status,triage';
}

function assertLegacySchema(db) {
  const columns = db.pragma('table_info(triage_reports)')
    .map((column) => column.name);
  const missing = REPORT_COLUMNS.filter((column) => !columns.includes(column));
  if (missing.length > 0) {
    throw new Error(
      `Existing triage_reports table is missing required columns: ${missing.join(', ')}`,
    );
  }
  if (!hasUniqueReportIdentity(db)) {
    throw new Error(
      'Existing triage_reports table lacks UNIQUE(watch_id, created_at); refusing to adopt it',
    );
  }
  if (!hasStatusIndex(db)) {
    throw new Error(
      'Hub migration did not create the expected idx_reports_status(status, triage) index',
    );
  }
}

function migrate(db) {
  db.transaction(() => {
    const migrations = loadMigrations();
    const currentVersion = db.pragma('user_version', { simple: true });
    const latestVersion = migrations.at(-1).version;
    if (currentVersion > latestVersion) {
      throw new Error(`Hub database version ${currentVersion} is newer than supported version ${latestVersion}`);
    }
    if (currentVersion === 0 && hasTable(db, 'triage_reports')) assertLegacySchema(db);
    for (const migration of migrations.filter((item) => item.version > currentVersion)) {
      db.exec(migration.sql);
      if (migration.version === 2) require('./clinical').backfillReports(db);
      db.pragma(`user_version = ${migration.version}`);
    }
    assertLegacySchema(db);
    assertClinicalSchema(db);
  }).immediate();
}

function assertClinicalSchema(db) {
  // Prepare against every relationship before accepting a versioned database.
  db.prepare(`SELECT e.patient_count_known, e.processing_json, e.submitted_json, v.state_json, v.assessment_json,
    p.name, c.patient_id FROM report_evidence e JOIN report_revisions v ON v.report_id = e.report_id
    JOIN encounter_revisions c ON c.encounter_id = e.encounter_id LEFT JOIN patient_revisions p ON p.patient_id = c.patient_id LIMIT 0`);
  if (db.pragma('foreign_key_check').length || db.prepare(`SELECT 1 FROM triage_reports r
    WHERE NOT EXISTS (SELECT 1 FROM report_evidence e WHERE e.report_id = r.id)
      OR NOT EXISTS (SELECT 1 FROM report_revisions v WHERE v.report_id = r.id AND v.revision = 0) LIMIT 1`).get()) {
    throw new Error('Hub clinical history is incomplete; refusing to open database');
  }
  db.prepare(`SELECT c.report_id, c.cloud_report_id, c.queued_at, c.synced_at, c.owner_id, c.rejected_reason
    FROM cloud_sync c JOIN triage_reports r ON r.id = c.report_id LIMIT 0`);
}

function openDb(file = process.env.DB_PATH || path.join(__dirname, 'data', 'vanguard.db')) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new Database(file);
  try {
    db.pragma('busy_timeout = 5000');
    db.pragma('journal_mode = WAL');
    db.pragma('synchronous = FULL');
    db.pragma('foreign_keys = ON');
    migrate(db);
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

module.exports = { openDb };
