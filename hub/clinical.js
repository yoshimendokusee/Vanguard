const { randomUUID } = require('node:crypto');
const { validateProcessing, text } = require('./processing');
const { assessRisk, riskForRow } = require('./risk');
const { fail, encode, validateEdit, getRecord } = require('./records');

const UNKNOWN = { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' };
const RANK = { Immediate: 0, Unassessed: 1, Delayed: 2, Minor: 3, Deceased: 4 };

function validateReportId(id) {
  if (!/^[1-9]\d*$/.test(String(id)) || !Number.isSafeInteger(Number(id))) fail(400, 'Bad report ID');
}

function assessment(row, state) {
  let result;
  const uncertainties = [...(state.processing?.uncertainties || [])];
  if (state.processing) {
    const p = state.processing;
    const observations = { ...UNKNOWN };
    for (const finding of p.findings) {
      if (finding.contradictory || p.findings.some((other) => other.kind === finding.kind && other.name === finding.name
        && other.value !== null && finding.value !== null && (other.value !== finding.value || other.unit !== finding.unit))) {
        uncertainties.push(`${finding.name}: contradictory findings; verification required`);
      }
    }
    for (const [key, value] of Object.entries(p.observations)) {
      const source = p.evidence[key];
      const conflicts = p.findings.filter((finding) => finding.name === key);
      const contradictory = conflicts.some((finding) => finding.contradictory)
        || conflicts.some((finding) => finding.value !== null && finding.value !== value);
      if (value !== 'unknown' && source && !p.provenance.extraction && source.source !== 'model-inferred'
        && !source.contradictory && !contradictory) {
        observations[key] = value;
      } else if (value !== 'unknown') uncertainties.push(`${key}: unsupported, inferred or contradictory; assessment required`);
    }
    const risk = assessRisk(observations);
    result = { provisional_triage: risk.triage, rule_version: risk.version, risk_reason: risk.reason,
      assessed_observations: observations };
  } else if (state.transcriptChanged) {
    result = { provisional_triage: 'Unassessed', rule_version: 'provisional-v1',
      risk_reason: 'Transcript corrected; stale extraction invalidated', assessed_observations: { ...UNKNOWN } };
  } else result = riskForRow(row);
  const computed = RANK[row.triage] < RANK[result.provisional_triage] ? row.triage : result.provisional_triage;
  return { ...result, effective_triage: state.override ?? computed, computed_triage: computed,
    clinician_override: state.override, requires_verification: true, uncertainties: [...new Set(uncertainties)] };
}

function ensureEncounter(db, id, at) {
  if (db.prepare('SELECT 1 FROM encounters WHERE id = ?').get(id)) return;
  db.prepare('INSERT INTO encounters (id, created_at) VALUES (?, ?)').run(id, at);
  db.prepare(`INSERT INTO encounter_revisions (encounter_id, revision, request_id, actor, reason,
    patient_id, incident, payload_json, created_at) VALUES (?, 0, ?, 'intake', 'Identity not supplied', NULL, NULL, '{}', ?)`).run(id, randomUUID(), at);
}

function initializeReport(db, row, value = null, submitted = null) {
  const encounterId = value?.encounterId || randomUUID();
  const assessedAt = value ? row.received_at : new Date().toISOString();
  ensureEncounter(db, encounterId, assessedAt);
  const processing = value?.processing ?? null;
  db.prepare(`INSERT INTO report_evidence (report_id, encounter_id, source_report_id, patient_count_known, processing_json, submitted_json)
    VALUES (?, ?, ?, ?, ?, ?)`).run(row.id, encounterId, value?.reportId ?? null, value?.patientCountKnown ? 1 : 0,
    processing === null ? null : encode(processing), encode(submitted || row));
  const state = { transcript: processing?.originalTranscript ?? row.raw_text, processing, override: null, transcriptChanged: false };
  db.prepare(`INSERT INTO report_revisions (report_id, revision, request_id, kind, actor, reason,
    payload_json, state_json, assessment_json, created_at) VALUES (?, 0, ?, 'intake', ?, ?, ?, ?, ?, ?)`)
    .run(row.id, randomUUID(), value ? 'intake' : 'migration', value ? 'Original submission' : 'Legacy source adopted; assessment computed during migration',
      encode(value || row), encode(state), encode(assessment(row, state)), assessedAt);
  db.prepare("INSERT INTO report_events (report_id, event, detail, created_at) VALUES (?, 'received', ?, ?)")
    .run(row.id, value ? 'Persisted at hospital LAN hub; response receipt by client unknown'
      : 'Legacy stored receipt adopted; response receipt by client unknown', row.received_at);
}

function backfillReports(db) {
  for (const row of db.prepare('SELECT * FROM triage_reports').all()) initializeReport(db, row);
}

const REPORT_VIEW = `SELECT r.*, e.encounter_id, e.source_report_id, e.patient_count_known, e.submitted_json,
  v.revision, v.state_json, v.assessment_json FROM triage_reports r
  JOIN report_evidence e ON e.report_id = r.id JOIN report_revisions v ON v.report_id = r.id
    AND v.revision = (SELECT MAX(revision) FROM report_revisions WHERE report_id = r.id)`;

function viewFromRow({ state_json, assessment_json, submitted_json, ...row }) {
  const state = JSON.parse(state_json);
  return { ...row, ...JSON.parse(assessment_json),
    current_transcript: state.transcript, processing: state.processing,
    source_findings_current: !state.transcriptChanged && state.processing === null,
    receipt_state: 'received', patient_count_known: Boolean(row.patient_count_known) };
}

function listReports(db) {
  const rows = db.prepare(`${REPORT_VIEW} ORDER BY (r.status != 'inbound'),
    (r.eta_minutes IS NULL), strftime('%s', r.created_at) + COALESCE(r.eta_minutes, 0) * 60, r.created_at, r.id`).all().map(viewFromRow);
  return rows.sort((a, b) => Number(a.status !== 'inbound') - Number(b.status !== 'inbound')
    || RANK[a.effective_triage] - RANK[b.effective_triage]);
}

function reportView(db, id, withHistory = false) {
  validateReportId(id);
  const row = db.prepare(`${REPORT_VIEW} WHERE r.id = ?`).get(id);
  if (!row) fail(404, 'Report not found');
  const result = viewFromRow(row);
  if (withHistory) {
    result.history = db.prepare('SELECT * FROM report_revisions WHERE report_id = ? ORDER BY revision').all(id)
      .map(({ state_json, assessment_json, payload_json, ...revision }) => ({ ...revision,
        state: JSON.parse(state_json), assessment: JSON.parse(assessment_json), payload: JSON.parse(payload_json) }));
    result.events = db.prepare('SELECT * FROM report_events WHERE report_id = ? ORDER BY id').all(id);
    result.encounter = getRecord(db, 'encounter', row.encounter_id);
    result.original_submission = JSON.parse(row.submitted_json);
  }
  return result;
}

function reviseReport(db, id, input) {
  validateReportId(id);
  validateEdit(input);
  if (!['correction', 'extraction', 'override'].includes(input.kind)) fail(400, 'Invalid revision kind');
  const allowed = ['requestId', 'baseRevision', 'actor', 'reason', 'kind',
    ...(input.kind === 'correction' ? ['transcript', 'processing'] : input.kind === 'extraction' ? ['processing'] : ['override'])];
  if (Object.keys(input).some((key) => !allowed.includes(key))) fail(400, 'Unsupported revision field');
  const payload = encode(input);
  const requestId = input.requestId.toLowerCase();
  return db.transaction(() => {
    const replay = db.prepare('SELECT payload_json FROM report_revisions WHERE report_id = ? AND request_id = ?').get(id, requestId);
    if (replay) {
      if (replay.payload_json !== payload) fail(409, 'Request ID conflict');
      return reportView(db, id, true);
    }
    const row = db.prepare('SELECT * FROM triage_reports WHERE id = ?').get(id);
    if (!row) fail(404, 'Report not found');
    const latest = db.prepare('SELECT * FROM report_revisions WHERE report_id = ? ORDER BY revision DESC LIMIT 1').get(id);
    if (latest.revision !== input.baseRevision) fail(409, 'Stale base revision');
    const state = JSON.parse(latest.state_json);
    if (input.kind === 'correction') {
      if (!text(input.transcript, 16000, true)) fail(400, 'Invalid corrected transcript');
      state.transcript = input.transcript;
      state.transcriptChanged = true;
      state.processing = null;
      // A correction invalidates the previous clinician decision as well as extraction.
      state.override = null;
    }
    if (input.kind === 'extraction' || input.processing !== undefined) {
      const checked = validateProcessing(input.processing);
      if (checked.error) fail(400, checked.error);
      if (checked.value.originalTranscript !== state.transcript) fail(409, 'Extraction transcript differs from current revision');
      state.processing = checked.value;
    }
    if (input.kind === 'override') {
      if (!(input.override === null || ['Immediate', 'Unassessed', 'Delayed', 'Minor'].includes(input.override))) fail(400, 'Invalid provisional override');
      state.override = input.override;
    }
    const now = new Date().toISOString();
    db.prepare(`INSERT INTO report_revisions (report_id, revision, request_id, kind, actor, reason,
      payload_json, state_json, assessment_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(id, latest.revision + 1, requestId, input.kind, input.actor, input.reason, payload, encode(state), encode(assessment(row, state)), now);
    return reportView(db, id, true);
  }).immediate();
}

module.exports = { backfillReports, initializeReport, reportView, listReports, reviseReport };
