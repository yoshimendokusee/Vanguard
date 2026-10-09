const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { openDb } = require('./db');
const { validateProcessing } = require('./processing');
const { validateReport, ingestBatch } = require('./sync');
const { reportView } = require('./clinical');

// docs/fixtures/native-processing-v1.json is produced by the Swift app code (HubContractTests). The hub's own
// validator and intake must accept it, so the watch cannot drift into an envelope the hospital rejects.
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, '../docs/fixtures/native-processing-v1.json'), 'utf8'));

test('the hub validator accepts the Swift processing envelope, findings included', () => {
  const checked = validateProcessing(fixture.processing);
  assert.equal(checked.error, undefined);
  assert.ok(checked.value.findings.length >= 2);
  for (const finding of checked.value.findings) {
    assert.ok(fixture.processing.originalTranscript.includes(finding.excerpt), `${finding.name} is quoted from the transcript`);
    assert.equal(finding.source === 'reported' || finding.source === 'model-inferred', true);
  }
  assert.deepEqual(Object.keys(checked.value.observations).sort(), ['breathing', 'circulation', 'consciousness', 'severeBleeding', 'walking']);
  assert.ok(checked.value.findings.every(f => f.kind === 'symptom'), 'RAG terms remain without patient or incident extraction');
  assert.ok(!checked.value.findings.some((f) => f.kind === 'vital'), 'no vital sign is invented');
});

test('a value-less finding must carry an explicit null, which is what Swift sends', () => {
  const broken = JSON.parse(JSON.stringify(fixture.processing));
  delete broken.findings.find((f) => f.value === null).value;
  assert.equal(validateProcessing(broken).error, 'invalid finding source reference');
});

test('a native report with these details is stored with its findings and unknown fields kept unknown', () => {
  const db = openDb(':memory:');
  const reportId = randomUUID();
  const body = { localId: 1, reportId, encounterId: randomUUID(), createdAt: '2026-10-10T01:00:00.000Z', triage: 'Unassessed',
    location: 'Unspecified', injuries: 'Unspecified', patientCount: null, ageGroup: fixture.extraction.details.ageGroup,
    etaMinutes: null, rawText: fixture.processing.originalTranscript, processing: fixture.processing };
  assert.equal(validateReport(body).error, undefined);
  const result = ingestBatch(db, 'APPLE-WATCH-SYNTHETIC', [body]);
  assert.deepEqual(result.ackLocalIds, [1]);
  const row = db.prepare('SELECT id FROM triage_reports').get();
  const view = reportView(db, row.id);
  assert.equal(view.patient_count_known, false, 'an unknown count is not treated as zero or one');
  assert.equal(view.age_group, 'Unspecified'); assert.equal(view.eta_minutes, null);
  assert.equal(view.processing.findings.length, fixture.processing.findings.length);
  // Model-inferred observations never drive the hospital's assessment without verification.
  assert.equal(view.effective_triage, 'Unassessed');
});
