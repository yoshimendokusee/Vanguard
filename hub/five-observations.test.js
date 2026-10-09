const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');
const { toValidatedExtraction, SYSTEM_PROMPT } = require('./ai');
const { validateProcessing } = require('./processing');
const { OBSERVATIONS, assessRisk } = require('./risk');
const { openDb } = require('./db');
const { ingestBatch } = require('./sync');
const { initializeReport, reportView, reviseReport } = require('./clinical');
const fixture = require('../docs/fixtures/five-observations-v1.json');
const unknown = Object.fromEntries(Object.keys(OBSERVATIONS).map(k => [k, 'unknown']));

test('five observations are grounded across multilingual, ambiguous and hostile synthetic speech', () => {
  for (const item of fixture.cases) {
    for (const claims of [unknown, item.expected, { breathing: 'normal', consciousness: 'alert', severeBleeding: 'present', walking: 'able', circulation: 'present' }]) {
      const result = toValidatedExtraction(claims, item.transcript);
      assert.deepEqual(result.observations, item.expected, item.transcript);
      for (const [key, excerpt] of Object.entries(result.evidence)) {
        if (excerpt !== null) assert.ok(item.transcript.includes(excerpt), key);
        else assert.equal(result.observations[key], 'unknown');
      }
    }
  }
  assert.deepEqual(require('./observation-phrases.json'), require('../watch/apple/Sources/VanguardApple/Resources/observation-phrases.json'));
  const swift = fs.readFileSync('../watch/apple/Sources/VanguardApple/NativeClinical.swift', 'utf8');
  assert.ok(SYSTEM_PROMPT.split('\n').every(line => swift.includes(line)), 'Apple and hub use the same five-field Qwen prompt');
});

const processing = (transcript) => {
  const result = toValidatedExtraction(unknown, transcript);
  return { version: 1, originalTranscript: transcript, observations: result.observations, uncertainties: result.uncertainties,
    evidence: Object.fromEntries(Object.entries(result.evidence).filter(([, quote]) => quote !== null).map(([key, excerpt]) => [key, { source: 'model-inferred', excerpt, contradictory: false }])),
    provenance: { device: 'iphone', sttEngine: 'synthetic/on-device', sttRuntime: 'synthetic', extraction: { model: 'Qwen3-0.6B', revision: 'synthetic', runtime: 'test', execution: 'local', artifactSha256: 'a'.repeat(64) } } };
};

test('SQLite reopen, retries and corrections preserve five fields, identity and immutable history', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-five-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'synthetic.sqlite');
  let db = openDb(file);
  const transcript = fixture.cases.find(c => c.expected.circulation === 'present' && c.expected.walking === 'unable').transcript;
  const body = { localId: 1, reportId: randomUUID(), encounterId: randomUUID(), createdAt: '2026-10-10T00:00:00Z', rawText: transcript,
    triage: 'Unassessed', location: 'Unspecified', injuries: 'Unspecified', processing: processing(transcript) };
  const id = ingestBatch(db, 'APPLE-WATCH-SYNTHETIC-FIVE', [body]).inserted[0].id;
  db.close(); db = openDb(file); t.after(() => db.close());
  const view = reportView(db, id, true);
  assert.equal(view.processing.observations.circulation, 'present');
  assert.equal(view.effective_triage, 'Unassessed', 'machine claims remain provisional');
  assert.equal(view.encounter_id, body.encounterId);
  assert.deepEqual(ingestBatch(db, 'APPLE-WATCH-SYNTHETIC-FIVE', [{ ...body, localId: 2 }]).ackLocalIds, [2]);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM triage_reports').get().n, 1);
  const corrected = 'Synthetic patient cannot walk. No radial pulse.';
  const changed = reviseReport(db, id, { kind: 'correction', transcript: corrected, processing: processing(corrected), baseRevision: 0,
    requestId: randomUUID(), actor: 'Synthetic operator', reason: 'Synthetic correction' });
  assert.equal(changed.processing.observations.circulation, 'absent');
  assert.equal(changed.raw_text, transcript);
  assert.equal(changed.history[0].state.processing.observations.circulation, 'present');
  assert.equal(changed.history.length, 2);
});

test('historical four-field bytes and triage are preserved while retrieval defaults circulation to unknown', t => {
  const db = openDb(':memory:'); t.after(() => db.close());
  const p = validateProcessing(processing('Patient cannot walk.')).value;
  delete p.observations.circulation;
  db.prepare(`INSERT INTO triage_reports (watch_id, location, injuries, triage, patient_count, age_group, raw_text, created_at, received_at)
    VALUES ('LEGACY', 'Unspecified', 'Unspecified', 'Unassessed', 1, 'Unspecified', ?, '2026-10-10T00:00:00.000Z', '2026-10-10T00:00:01Z')`).run(p.originalTranscript);
  const row = db.prepare('SELECT * FROM triage_reports').get();
  initializeReport(db, row, { processing: p });
  const bytes = db.prepare('SELECT processing_json FROM report_evidence').get().processing_json;
  assert.equal(reportView(db, row.id).processing.observations.circulation, 'unknown');
  const replay = ingestBatch(db, 'LEGACY', [{ localId: 8, createdAt: row.created_at, rawText: p.originalTranscript, injuries: row.injuries,
    triage: row.triage, location: row.location, patientCount: 1, processing: p }]);
  assert.deepEqual(replay.ackLocalIds, [8]);
  assert.equal(db.prepare('SELECT processing_json FROM report_evidence').get().processing_json, bytes);
  assert.equal(Object.hasOwn(reportView(db, row.id, true).history[0].state.processing.observations, 'circulation'), false);
  for (const circulation of ['heart-rate', null, 80]) assert.equal(validateProcessing({ ...p, observations: { ...p.observations, circulation } }).error, 'invalid processing');
});

test('circulation is stored and displayed without introducing a clinical scoring rule', () => {
  for (const item of require('../docs/fixtures/triage-parity-v1.json').cases) {
    for (const circulation of OBSERVATIONS.circulation) assert.deepEqual(assessRisk({ ...item.observations, circulation }), item.expected);
  }
});

function renderer() {
  const document = { createElement: tag => ({ tag, children: [], dataset: {}, textContent: '', append(...nodes) { this.children.push(...nodes); } }) };
  const window = {};
  vm.runInNewContext(fs.readFileSync(__dirname + '/public/observations.js', 'utf8'), { window, document });
  return window.VanguardObservations;
}

test('dashboard renders five persisted values, refreshed corrections, and explicit historical unknowns', () => {
  const ui = renderer();
  const observations = fixture.cases.find(c => c.expected.walking === 'unable' && c.expected.circulation === 'present').expected;
  const rows = ui.render(observations).children;
  assert.equal(rows.length, 6);
  assert.equal(rows[1].textContent, 'Breathing: Difficulty breathing');
  assert.equal(rows[5].dataset.observation, 'circulation');
  assert.equal(rows[5].textContent, 'Circulation: Radial pulse palpable');
  assert.equal(ui.render({ ...observations, circulation: 'absent' }).children[5].textContent, 'Circulation: Radial pulse not palpable');
  assert.equal(ui.render().children[5].textContent, 'Circulation: Unknown / unassessed');
  assert.equal(ui.render({ circulation: '<script>bad</script>' }).children[5].textContent, 'Circulation: Unknown / unassessed');
});
