// Conflict resolution protocol for watch -> hospital batches.
//
// A rescuer may sync the same SQLite batch twice (flaky Wi-Fi, double tap,
// watch crashed before it marked rows synced). Keep the legacy identity
// (watch_id, created_at); compare evidence before acknowledging any replay.
// A double-counted casualty would make the ED prepare for patients who don't
// exist, so this check matters more here than in most sync code.

const TRIAGE = new Set(['Immediate', 'Unassessed', 'Delayed', 'Minor', 'Deceased']);
const AGE_GROUPS = new Set(['Infant', 'Child', 'Adult', 'Elderly', 'Unspecified']);
const MAX_BATCH = 500;
const { validateProcessing, text } = require('./processing');
const { isId, encode } = require('./records');
const { initializeReport } = require('./clinical');

/** Returns { value } for a usable report, or { error } explaining why not. */
function validateReport(r) {
  if (!r || typeof r !== 'object' || Array.isArray(r)) return { error: 'not an object' };
  if (r.localId !== undefined && (!Number.isSafeInteger(r.localId) || r.localId <= 0)) return { error: 'invalid localId' };
  if (typeof r.createdAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(r.createdAt)) return { error: 'invalid createdAt' };
  const createdMs = Date.parse(r.createdAt);
  if (Number.isNaN(createdMs)) return { error: 'invalid createdAt' };
  const [year, month, day] = r.createdAt.slice(0, 10).split('-').map(Number);
  if (month < 1 || month > 12 || day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return { error: 'invalid createdAt' };
  if (!TRIAGE.has(r.triage)) return { error: 'invalid triage category' };

  const patientCount = r.patientCount == null ? 1 : r.patientCount;
  if (!Number.isInteger(patientCount) || patientCount < 1 || patientCount > 99) {
    return { error: 'invalid patientCount' };
  }

  const ageGroup = r.ageGroup === undefined ? 'Unspecified' : r.ageGroup;
  if (!AGE_GROUPS.has(ageGroup)) return { error: 'invalid ageGroup' };

  const eta = r.etaMinutes === undefined || r.etaMinutes === null ? null : r.etaMinutes;
  if (eta !== null && (!Number.isInteger(eta) || eta < 1 || eta > 720)) {
    return { error: 'invalid etaMinutes' };
  }

  if (!text(r.location, 200) || !text(r.injuries, 300)) return { error: 'missing or over-limit location/injuries' };
  const location = r.location.trim();
  const injuries = r.injuries.trim();
  let processing = null;
  if (r.processing !== undefined) {
    const checked = validateProcessing(r.processing);
    if (checked.error) return { error: checked.error };
    processing = checked.value;
  }
  if (r.rawText !== undefined && !text(r.rawText, 16000, true)) return { error: 'invalid or over-limit rawText; retain original locally' };
  if (processing && r.rawText !== undefined && processing.originalTranscript !== r.rawText) return { error: 'original transcript differs from rawText' };
  if (r.encounterId !== undefined && !isId(r.encounterId)) return { error: 'invalid encounterId' };
  if (r.reportId !== undefined && !isId(r.reportId)) return { error: 'invalid reportId' };
  return {
    value: {
      location,
      injuries,
      triage: r.triage,
      patientCount,
      ageGroup,
      etaMinutes: eta,
      rawText: r.rawText ?? processing?.originalTranscript ?? '',
      patientCountKnown: Number.isInteger(r.patientCount),
      processing,
      encounterId: r.encounterId?.toLowerCase() ?? null,
      reportId: r.reportId?.toLowerCase() ?? null,
      // Normalize so "…12:00:00.1Z" and "…12:00:00.100Z" can't dodge the dedupe.
      createdAt: new Date(createdMs).toISOString(),
    },
  };
}

/**
 * Ingest one batch atomically.
 * Returns { inserted: [row...], duplicates, rejected: [{localId, reason}], ackLocalIds }.
 */
function ingestBatch(db, watchId, reports) {
  const insert = db.prepare(`
    INSERT INTO triage_reports
      (watch_id, location, injuries, triage, patient_count, age_group, eta_minutes,
       raw_text, created_at, received_at)
    VALUES (@watchId, @location, @injuries, @triage, @patientCount, @ageGroup, @etaMinutes,
            @rawText, @createdAt, @receivedAt)
    ON CONFLICT(watch_id, created_at) DO NOTHING
  `);
  const getRow = db.prepare('SELECT * FROM triage_reports WHERE id = ?');
  const existing = db.prepare(`SELECT r.*, e.processing_json, e.source_report_id, e.encounter_id, e.patient_count_known, v.payload_json
    FROM triage_reports r JOIN report_evidence e ON e.report_id = r.id
    JOIN report_revisions v ON v.report_id = r.id AND v.revision = 0 WHERE watch_id = ? AND r.created_at = ?`);

  const out = { inserted: [], duplicates: 0, rejected: [], ackLocalIds: [] };
  const receivedAt = new Date().toISOString();
  const localIds = new Map();
  for (const raw of reports) if (raw && Number.isSafeInteger(raw.localId)) localIds.set(raw.localId, (localIds.get(raw.localId) || 0) + 1);

  db.transaction(() => {
    for (const raw of reports) {
      const localId = raw && Number.isInteger(raw.localId) ? raw.localId : null;
      if (localIds.get(localId) > 1) {
        out.rejected.push({ localId, reason: 'ambiguous duplicate localId' });
        continue;
      }
      const { value, error } = validateReport(raw);
      if (error) {
        out.rejected.push({ localId, reason: error });
        continue; // not ACKed -> stays queued on the watch
      }
      const row = existing.get(watchId, value.createdAt);
      if (row) {
        const fields = { location: 'location', injuries: 'injuries', triage: 'triage', patientCount: 'patient_count',
          ageGroup: 'age_group', etaMinutes: 'eta_minutes', rawText: 'raw_text' };
        if (Object.entries(fields).some(([key, column]) => value[key] !== row[column])
          || (value.processing === null ? null : encode(value.processing)) !== row.processing_json
          || value.reportId !== row.source_report_id || (value.encounterId !== null && value.encounterId !== row.encounter_id)
          || (Object.hasOwn(JSON.parse(row.payload_json), 'patientCountKnown')
            && value.patientCountKnown !== Boolean(row.patient_count_known))) {
          out.rejected.push({ localId, reason: 'identity conflict: original report differs' });
          continue;
        }
        out.duplicates += 1;
      } else {
        if (value.reportId && db.prepare('SELECT 1 FROM report_evidence WHERE source_report_id = ?').get(value.reportId)) {
          out.rejected.push({ localId, reason: 'reportId already belongs to a different legacy identity' });
          continue;
        }
        const info = insert.run({ watchId, receivedAt, ...value });
        const stored = getRow.get(info.lastInsertRowid);
        initializeReport(db, stored, value, raw);
        out.inserted.push(stored);
      }
      if (localId !== null) out.ackLocalIds.push(localId);
    }
  }).immediate();

  return out;
}

module.exports = { ingestBatch, validateReport, MAX_BATCH };
