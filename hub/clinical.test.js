const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { once } = require('node:events');
const { openDb } = require('./db');
const { createApp } = require('./server');
const { ingestBatch, validateReport } = require('./sync');
const { reportView, reviseReport } = require('./clinical');
const { saveRecord, getRecord } = require('./records');

const unknown = { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' };
const transcript = '  Synthetic subject is unresponsive. Breathing is not assessed.  ';
const processing = (over = {}) => ({ version: 1, originalTranscript: transcript,
  observations: { ...unknown, consciousness: 'unresponsive' }, uncertainties: ['Breathing not assessed'],
  provenance: { device: 'iphone', sttEngine: 'synthetic-test', sttRuntime: 'test-v1', extraction: null },
  evidence: { consciousness: { source: 'reported', excerpt: 'subject is unresponsive', contradictory: false } },
  findings: [{ id: 'finding-1', kind: 'observation', name: 'consciousness', value: 'unresponsive',
    source: 'reported', excerpt: 'subject is unresponsive', contradictory: false }], ...over });
const report = (over = {}) => ({ localId: 1, location: 'Synthetic pickup', injuries: 'Unspecified',
  triage: 'Unassessed', rawText: transcript, patientCount: 1, createdAt: '2026-10-09T00:00:00Z', ...over });
const edit = (baseRevision, kind, over = {}) => ({ requestId: randomUUID(), baseRevision, kind,
  actor: 'Synthetic operator', reason: 'Synthetic reassessment', ...over });
const fixture = (t) => { const db = openDb(':memory:'); t.after(() => db.close()); return db; };

test('structured report -> persistence -> provisional priority preserves source, evidence and replay identity', (t) => {
  const db = fixture(t);
  const encounterId = randomUUID();
  const input = report({ processing: processing(), reportId: randomUUID(), encounterId });
  const result = ingestBatch(db, 'W-SYNTHETIC', [input]);
  assert.deepEqual(result.ackLocalIds, [1]);
  const view = reportView(db, result.inserted[0].id, true);
  assert.equal(view.raw_text, transcript);
  assert.equal(view.current_transcript, transcript);
  assert.equal(view.triage, 'Unassessed');
  assert.equal(view.effective_triage, 'Immediate');
  assert.equal(view.rule_version, 'provisional-v1');
  assert.equal(view.history.length, 1);
  assert.equal(view.encounter.patient_id, null);
  assert.equal(view.encounter_id, encounterId);
  assert.equal(view.processing.findings[0].excerpt, 'subject is unresponsive');
  assert.equal(view.events[0].event, 'received');
  assert.equal(view.original_submission.rawText, transcript);
  assert.equal(ingestBatch(db, 'W-SYNTHETIC', [{ ...input, localId: 22 }]).duplicates, 1);
  const second = report({ localId: 2, encounterId, createdAt: '2026-10-09T00:00:01Z' });
  ingestBatch(db, 'W-SYNTHETIC', [second]);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM report_evidence WHERE encounter_id = ?').get(encounterId).n, 2);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM encounters').get().n, 1);
  assert.deepEqual(ingestBatch(db, 'W-SYNTHETIC', [{ ...input, processing: processing({ uncertainties: ['Different'] }) }]).ackLocalIds, []);
  assert.deepEqual(ingestBatch(db, 'W-SYNTHETIC', [{ ...input, createdAt: '2026-10-09T00:00:02Z' }]).ackLocalIds, []);
});

test('missing, conflicting and model-inferred observations never become established facts', (t) => {
  const db = fixture(t);
  for (const [index, p] of [processing({ evidence: {} }), processing({ evidence: {
    consciousness: { source: 'reported', excerpt: 'subject is unresponsive', contradictory: true } } }),
  processing({ evidence: { consciousness: { source: 'model-inferred', excerpt: 'subject is unresponsive', contradictory: false } } }),
  processing({ provenance: { ...processing().provenance, extraction: { model: 'synthetic-model', revision: 'test',
    runtime: 'test', execution: 'local', artifactSha256: 'a'.repeat(64) } } }),
  processing({ findings: [...processing().findings, { ...processing().findings[0], id: 'finding-2', value: 'alert' }] }),
  processing({ findings: [{ ...processing().findings[0], value: 'alert' }] })].entries()) {
    const result = ingestBatch(db, `W-UNKNOWN-${index}`, [report({ processing: p })]);
    const view = reportView(db, result.inserted[0].id);
    assert.equal(view.effective_triage, 'Unassessed');
    assert.equal(view.assessed_observations.consciousness, 'unknown');
    assert.ok(view.uncertainties.length);
    assert.equal(view.processing.observations.consciousness, 'unresponsive', 'Original claim remains evidence');
  }
  assert.match(validateReport(report({ processing: processing({ evidence: { consciousness: {
    source: 'reported', excerpt: 'Invented excerpt', contradictory: false } } }) })).error, /source reference/);
});

test('corrections invalidate stale findings and override; reassessments append with optimistic concurrency', (t) => {
  const db = fixture(t);
  const id = ingestBatch(db, 'W-REVISION', [report({ processing: processing() })]).inserted[0].id;
  const override = edit(0, 'override', { override: 'Delayed' });
  let view = reviseReport(db, id, override);
  assert.equal(view.effective_triage, 'Delayed');
  assert.equal(view.computed_triage, 'Immediate');
  assert.equal(reviseReport(db, id, { ...override }).revision, 1);
  assert.throws(() => reviseReport(db, id, { ...override, override: 'Minor' }), /Request ID conflict/);
  assert.throws(() => reviseReport(db, id, edit(0, 'override', { override: null })), /Stale base revision/);
  const correction = edit(1, 'correction', { transcript: 'Synthetic corrected transcript' });
  view = reviseReport(db, id, correction);
  assert.equal(view.revision, 2);
  assert.equal(view.processing, null);
  assert.equal(view.clinician_override, null);
  assert.equal(view.effective_triage, 'Unassessed');
  assert.equal(view.raw_text, transcript);
  assert.throws(() => reviseReport(db, id, edit(2, 'extraction', { processing: processing() })), /differs from current/);
  const p = processing({ originalTranscript: 'Synthetic corrected transcript', observations: unknown, evidence: {}, findings: [] });
  view = reviseReport(db, id, edit(2, 'extraction', { processing: p }));
  assert.equal(view.history.length, 4);
  assert.equal(view.history[0].assessment.effective_triage, 'Immediate');
  assert.equal(view.history[1].state.override, 'Delayed');
  assert.equal(view.history[2].state.transcript, correction.transcript);
  assert.throws(() => db.prepare("UPDATE triage_reports SET raw_text = 'changed' WHERE id = ?").run(id), /immutable/);
  assert.throws(() => db.prepare('DELETE FROM report_revisions WHERE report_id = ?').run(id), /immutable/);
  assert.throws(() => reviseReport(db, id, edit(3, 'override', { override: 'Deceased' })), /Invalid provisional override/);
});

test('unknown patients and encounters support explicit linkage and append-only identity changes without name merging', (t) => {
  const db = fixture(t);
  const patientId = randomUUID();
  const create = { patientId, requestId: randomUUID(), actor: 'Synthetic operator', reason: 'Unknown intake', identityStatus: 'unknown', name: null };
  saveRecord(db, 'patient', patientId, create, true);
  assert.equal(saveRecord(db, 'patient', patientId, create, true).revision, 0);
  const named = { requestId: randomUUID(), baseRevision: 0, actor: 'Synthetic operator', reason: 'Name reported', identityStatus: 'reported', name: 'SYNTHETIC NAME' };
  saveRecord(db, 'patient', patientId, named);
  assert.equal(getRecord(db, 'patient', patientId).history[0].name, null);
  const otherId = randomUUID();
  saveRecord(db, 'patient', otherId, { ...create, patientId: otherId, requestId: randomUUID(), identityStatus: 'reported', name: named.name }, true);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM patients').get().n, 2);
  assert.throws(() => saveRecord(db, 'patient', patientId.toUpperCase(), { ...create, patientId: patientId.toUpperCase(), requestId: randomUUID() }, true), /already exists/);
  const encounterId = randomUUID();
  saveRecord(db, 'encounter', encounterId, { encounterId, requestId: randomUUID(), actor: 'Synthetic operator', reason: 'Initial incident', patientId: null, incident: null }, true);
  saveRecord(db, 'encounter', encounterId, { requestId: randomUUID(), baseRevision: 0, actor: 'Synthetic operator', reason: 'Identity reported', patientId, incident: 'Synthetic incident' });
  assert.equal(getRecord(db, 'encounter', encounterId).history[0].patient_id, null);
  assert.equal(getRecord(db, 'encounter', encounterId).patient_id, patientId);
  assert.throws(() => saveRecord(db, 'patient', patientId, { ...named, requestId: randomUUID() }), /Stale/);
  assert.throws(() => saveRecord(db, 'patient', randomUUID(), { ...create, name: 'Invented identity' }, true), /Invalid patient identity/);
  assert.throws(() => saveRecord(db, 'encounter', randomUUID(), { encounterId: randomUUID(), requestId: randomUUID(), actor: 'Test', reason: 'Test', patientId: randomUUID(), incident: null }, true), /Patient not found/);
  assert.equal(db.pragma('foreign_key_check').length, 0);
});

test('invalid identifiers, impossible dates, oversized evidence and ambiguous ACKs leave reports pending', (t) => {
  const db = fixture(t);
  for (const input of [report({ localId: -1 }), report({ createdAt: 2026 }), report({ createdAt: '2026-02-30T00:00:00Z' }),
    report({ location: 'x'.repeat(201) }), report({ rawText: 123 }), report({ reportId: 'wrong' }), report({ processing: [] })]) {
    assert.deepEqual(ingestBatch(db, 'W-INVALID', [input]).ackLocalIds, []);
  }
  const ambiguous = ingestBatch(db, 'W-AMBIGUOUS', [report(), report({ createdAt: '2026-10-09T00:00:01Z' })]);
  assert.equal(ambiguous.rejected.length, 2);
  assert.deepEqual(ambiguous.ackLocalIds, []);
  const long = ' Synthetic '.repeat(1000);
  const stored = ingestBatch(db, 'W-LONG', [report({ rawText: long, patientCount: null })]).inserted[0];
  assert.equal(stored.raw_text, long);
  assert.equal(reportView(db, stored.id).patient_count_known, false);
  assert.deepEqual(ingestBatch(db, 'W-LONG', [report({ rawText: long, patientCount: 1 })]).ackLocalIds, []);
});

test('failure after report insert rolls back encounter, history and receipt as one transaction', (t) => {
  const db = fixture(t);
  db.exec("CREATE TRIGGER synthetic_fail BEFORE INSERT ON report_events BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
  assert.throws(() => ingestBatch(db, 'W-ROLLBACK', [report()]), /synthetic failure/);
  for (const table of ['triage_reports', 'encounters', 'encounter_revisions', 'report_evidence', 'report_revisions', 'report_events']) {
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n, 0);
  }
});

test('HTTP workflow and structured errors use real SQLite; lost responses can be replayed safely', async (t) => {
  const db = fixture(t);
  const server = createApp(db).listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const send = (path, body, method = 'POST') => fetch(base + path, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const patientId = randomUUID();
  const patient = await send('/api/patients', { patientId, requestId: randomUUID(), actor: 'Synthetic operator',
    reason: 'Synthetic unknown intake', identityStatus: 'unknown', name: null });
  assert.equal(patient.status, 200);
  assert.equal((await patient.json()).name, null);
  const encounterId = randomUUID();
  const encounter = await send('/api/encounters', { encounterId, requestId: randomUUID(), actor: 'Synthetic operator',
    reason: 'Synthetic linkage', patientId, incident: null });
  assert.equal(encounter.status, 200);
  assert.equal((await encounter.json()).patient_id, patientId);
  const identity = await send(`/api/patients/${patientId}/revisions`, { requestId: randomUUID(), baseRevision: 0,
    actor: 'Synthetic operator', reason: 'Synthetic name reported', identityStatus: 'reported', name: 'SYNTHETIC NAME' });
  assert.equal(identity.status, 200);
  const patientHistory = await (await fetch(base + `/api/patients/${patientId}`)).json();
  assert.equal(patientHistory.history.length, 2);
  assert.equal(patientHistory.history[0].name, null);
  assert.equal((await fetch(base + `/api/encounters/${encounterId}`)).status, 200);
  const incident = await send(`/api/encounters/${encounterId}/revisions`, { requestId: randomUUID(), baseRevision: 0,
    actor: 'Synthetic operator', reason: 'Synthetic incident added', patientId, incident: 'SYNTHETIC incident' });
  assert.equal(incident.status, 200);
  const batch = { watchId: 'W-HTTP', reports: [report({ processing: processing(), encounterId })] };
  await send('/api/sync-triage', batch); // Simulate a lost acknowledgment by discarding the response.
  const replay = await (await send('/api/sync-triage', batch)).json();
  assert.equal(replay.duplicates, 1);
  assert.deepEqual(replay.ackLocalIds, [1]);
  const [row] = await (await fetch(base + '/api/triage')).json();
  assert.equal(row.encounter_id, encounterId);
  assert.equal(row.effective_triage, 'Immediate');
  const changed = await send(`/api/triage/${row.id}/revisions`, edit(0, 'correction', { transcript: 'Synthetic correction' }));
  assert.equal(changed.status, 200);
  assert.equal((await changed.json()).revision, 1);
  assert.equal((await (await fetch(base + `/api/triage/${row.id}`)).json()).history.length, 2);
  const stale = await send(`/api/triage/${row.id}/revisions`, edit(0, 'override', { override: null }));
  assert.equal(stale.status, 409);
  assert.deepEqual(await stale.json(), { ok: false, error: 'Stale base revision' });
  assert.equal((await send(`/api/triage/${row.id}`, { status: 'arrived' }, 'PATCH')).status, 200);
  assert.equal(reportView(db, row.id, true).events.at(-1).event, 'status');
  const malformed = await fetch(base + '/api/sync-triage', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{' });
  assert.equal(malformed.status, 400);
  assert.deepEqual(await malformed.json(), { ok: false, error: 'Malformed JSON' });
  const oversized = await send('/api/sync-triage', { padding: 'a'.repeat(1024 * 1024) });
  assert.equal(oversized.status, 413);
  assert.deepEqual(await oversized.json(), { ok: false, error: 'JSON body exceeds 1 MB' });
  db.exec("CREATE TRIGGER synthetic_offline BEFORE INSERT ON triage_reports BEGIN SELECT RAISE(ABORT, 'private database detail'); END");
  const unavailable = await send('/api/sync-triage', { ...batch, reports: [report({ createdAt: '2026-10-09T00:00:02Z' })] });
  assert.equal(unavailable.status, 503);
  assert.deepEqual(await unavailable.json(), { ok: false, error: 'Database unavailable; retain and retry' });
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM triage_reports').get().n, 1);
});
