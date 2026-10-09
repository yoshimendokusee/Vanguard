const test = require('node:test');
const assert = require('node:assert/strict');
const { assessRisk, riskForRow, validateObservations, LEGACY_RULES } = require('./risk');
const { validateProcessing } = require('./processing');
const { openDb } = require('./db');
const { ingestBatch } = require('./sync');

const unknown = { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' };
const report = (over = {}) => ({ localId: 1, location: 'Synthetic pickup', injuries: 'Unspecified', triage: 'Unassessed',
  rawText: 'Synthetic transcript', createdAt: '2026-10-09T00:00:00Z', ...over });

test('structured risk is deterministic and missing findings never imply normal', () => {
  assert.equal(assessRisk(unknown).triage, 'Unassessed');
  assert.equal(assessRisk({ ...unknown, walking: 'able' }).triage, 'Unassessed');
  assert.equal(assessRisk({ ...unknown, walking: 'unable' }).triage, 'Delayed');
  for (const finding of [{ breathing: 'absent' }, { breathing: 'abnormal' }, { consciousness: 'unresponsive' }, { severeBleeding: 'present' }]) {
    const risk = assessRisk({ ...unknown, ...finding });
    assert.equal(risk.triage, 'Immediate');
    assert.ok(risk.reason);
    assert.equal(risk.version, 'provisional-v1');
  }
  assert.equal(assessRisk({ breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' }).triage, 'Minor');
  assert.equal(validateObservations({ ...unknown, breathing: 'invented' }), false);
  assert.equal(validateObservations({ ...unknown, extra: true }), false);
});

test('legacy hospital rules match exact findings, keep unknowns and never downgrade urgent reports', () => {
  for (const [triage, findings] of Object.entries(LEGACY_RULES)) {
    for (const injuries of findings) assert.equal(riskForRow({ injuries, triage: 'Minor' }).provisional_triage, triage);
  }
  assert.equal(riskForRow({ injuries: 'Not severe bleeding', triage: 'Minor' }).effective_triage, 'Unassessed');
  assert.equal(riskForRow({ injuries: 'Unspecified', triage: 'Immediate' }).effective_triage, 'Immediate');
  assert.equal(riskForRow({ injuries: 'Ambulatory, Severe bleeding', triage: 'Minor' }).effective_triage, 'Immediate');
  assert.equal(riskForRow({ injuries: 'Deceased', triage: 'Deceased' }).effective_triage, 'Unassessed');
});

test('processing contract keeps long original text and rejects incomplete/locality provenance', () => {
  const input = { version: 1, originalTranscript: ' synthetic '.repeat(500), observations: unknown,
    uncertainties: ['Assessment incomplete'], provenance: { device: 'iphone', sttEngine: 'fixture', sttRuntime: 'fixture-v1' } };
  assert.equal(validateProcessing(input).value.originalTranscript, input.originalTranscript);
  assert.ok(validateProcessing({ ...input, observations: {} }).error);
  assert.ok(validateProcessing({ ...input, provenance: { ...input.provenance, extraction: { execution: 'cloud' } } }).error);
  const extraction = { model: 'Qwen3-0.6B', revision: 'fixture-revision', runtime: 'fixture-runtime',
    artifactSha256: 'a'.repeat(64), execution: 'local' };
  assert.deepEqual(validateProcessing({ ...input, provenance: { ...input.provenance, extraction } }).value.provenance.extraction, extraction);
});

test('invalid processing metadata is not silently discarded or acknowledged', () => {
  const db = openDb(':memory:');
  try {
    const result = ingestBatch(db, 'W-TEST', [report({ processing: {} })]);
    assert.deepEqual(result.ackLocalIds, []);
    assert.match(result.rejected[0].reason, /invalid processing/);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM triage_reports').get().n, 0);
  } finally { db.close(); }
});

test('legacy originals are exact; over-limit originals are refused without ACK', () => {
  const db = openDb(':memory:');
  try {
    const exact = '  Synthetic original with whitespace  ';
    assert.equal(ingestBatch(db, 'W-TEST', [report({ rawText: exact })]).inserted[0].raw_text, exact);
    const result = ingestBatch(db, 'W-LONG', [report({ rawText: 'a'.repeat(16001) })]);
    assert.deepEqual(result.ackLocalIds, []);
    assert.match(result.rejected[0].reason, /retain original locally/);
  } finally { db.close(); }
});

test('conflicting originals are not acknowledged; identical replays remain idempotent', () => {
  const db = openDb(':memory:');
  try {
    ingestBatch(db, 'W-TEST', [report()]);
    assert.deepEqual(ingestBatch(db, 'W-TEST', [report()]).ackLocalIds, [1]);
    const conflict = ingestBatch(db, 'W-TEST', [report({ rawText: 'Different synthetic original' })]);
    assert.deepEqual(conflict.ackLocalIds, []);
    assert.match(conflict.rejected[0].reason, /identity conflict/);
    assert.equal(db.prepare('SELECT raw_text FROM triage_reports').get().raw_text, 'Synthetic transcript');
  } finally { db.close(); }
});

test('ingest error rolls back the batch; no partial hospital receipt survives', () => {
  const db = openDb(':memory:');
  try {
    db.exec("CREATE TRIGGER fail_insert BEFORE INSERT ON triage_reports WHEN NEW.raw_text = 'fail' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
    assert.throws(() => ingestBatch(db, 'W-TEST', [report(), report({ localId: 2, createdAt: '2026-10-09T00:00:01Z', rawText: 'fail' })]));
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM triage_reports').get().n, 0);
  } finally { db.close(); }
});
