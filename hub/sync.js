// Conflict resolution protocol for watch -> hospital batches.
//
// A rescuer may sync the same SQLite batch twice (flaky Wi-Fi, double tap,
// watch crashed before it marked rows synced). Identity of a report is
// (watch_id, created_at): the watch guarantees strictly increasing timestamps,
// and the database enforces uniqueness. Replays are therefore harmless: the
// duplicate is skipped but still ACKed so the watch can mark it synced.
// A double-counted casualty would make the ED prepare for patients who don't
// exist, so this check matters more here than in most sync code.

const TRIAGE = new Set(['Immediate', 'Unassessed', 'Delayed', 'Minor', 'Deceased']);
const AGE_GROUPS = new Set(['Infant', 'Child', 'Adult', 'Elderly', 'Unspecified']);
const MAX_BATCH = 500;

function clean(value, max) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

/** Returns { value } for a usable report, or { error } explaining why not. */
function validateReport(r) {
  if (!r || typeof r !== 'object') return { error: 'not an object' };
  if (typeof r.rawText === 'string' && r.rawText.length > 1000) return { error: 'rawText exceeds legacy storage; retain original locally' };
  const createdMs = Date.parse(r.createdAt);
  if (Number.isNaN(createdMs)) return { error: 'invalid createdAt' };
  if (!TRIAGE.has(r.triage)) return { error: 'invalid triage category' };

  const patientCount = r.patientCount === undefined ? 1 : r.patientCount;
  if (!Number.isInteger(patientCount) || patientCount < 1 || patientCount > 99) {
    return { error: 'invalid patientCount' };
  }

  const ageGroup = r.ageGroup === undefined ? 'Unspecified' : r.ageGroup;
  if (!AGE_GROUPS.has(ageGroup)) return { error: 'invalid ageGroup' };

  const eta = r.etaMinutes === undefined || r.etaMinutes === null ? null : r.etaMinutes;
  if (eta !== null && (!Number.isInteger(eta) || eta < 1 || eta > 720)) {
    return { error: 'invalid etaMinutes' };
  }

  const location = clean(r.location, 200);
  const injuries = clean(r.injuries, 300);
  if (!location || !injuries) return { error: 'missing location/injuries' };
  if (r.processing !== undefined) {
    // Do not acknowledge metadata the current database cannot preserve.
    return { error: 'processing storage not integrated; retain report locally' };
  }
  return {
    value: {
      location,
      injuries,
      triage: r.triage,
      patientCount,
      ageGroup,
      etaMinutes: eta,
      rawText: typeof r.rawText === 'string' ? r.rawText : '',
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
  const existing = db.prepare('SELECT * FROM triage_reports WHERE watch_id = ? AND created_at = ?');

  const out = { inserted: [], duplicates: 0, rejected: [], ackLocalIds: [] };
  const receivedAt = new Date().toISOString();

  db.transaction(() => {
    for (const raw of reports) {
      const localId = raw && Number.isInteger(raw.localId) ? raw.localId : null;
      const { value, error } = validateReport(raw);
      if (error) {
        out.rejected.push({ localId, reason: error });
        continue; // not ACKed -> stays queued on the watch
      }
      const info = insert.run({ watchId, receivedAt, ...value });
      if (info.changes === 1) out.inserted.push(getRow.get(info.lastInsertRowid));
      else {
        const row = existing.get(watchId, value.createdAt);
        const fields = { location: 'location', injuries: 'injuries', triage: 'triage', patientCount: 'patient_count',
          ageGroup: 'age_group', etaMinutes: 'eta_minutes', rawText: 'raw_text' };
        if (Object.entries(fields).some(([key, column]) => value[key] !== row[column])) {
          out.rejected.push({ localId, reason: 'identity conflict: original report differs' });
          continue;
        }
        out.duplicates += 1;
      }
      if (localId !== null) out.ackLocalIds.push(localId);
    }
  })();

  return out;
}

module.exports = { ingestBatch, validateReport, MAX_BATCH };
