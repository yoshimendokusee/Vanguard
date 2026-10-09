const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { openDb } = require('./db');
const { createApp } = require('./server');
const { extractJsonObject, toValidatedExtraction, validateTranscriptInput, aiStatus } = require('./ai');

const artifact = Buffer.from('GGUF synthetic contract fixture, never real inference');
const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-ai-test-'));
const manifest = { ...require('../models/qwen3-0.6b/manifest.json'), file: 'fixture.gguf',
  sizeBytes: artifact.length, sha256: createHash('sha256').update(artifact).digest('hex') };
fs.writeFileSync(path.join(fixtureDir, manifest.file), artifact);
fs.writeFileSync(path.join(fixtureDir, 'manifest.json'), JSON.stringify(manifest));
test.after(() => fs.rmSync(fixtureDir, { recursive: true, force: true }));

const TRANSCRIPT = 'Synthetic patient is awake, breathing normally, no severe bleeding, can walk.';

// --- unit: input validation -------------------------------------------------
test('AI rejects empty and oversized transcripts without calling Ollama', () => {
  assert.equal(validateTranscriptInput({}, 4000).error.code, 'invalid-transcript');
  assert.equal(validateTranscriptInput({ transcript: '   ' }, 4000).error.code, 'invalid-transcript');
  assert.equal(validateTranscriptInput({ transcript: 7 }, 4000).error.code, 'invalid-transcript');
  assert.equal(validateTranscriptInput({ transcript: 'a'.repeat(4001) }, 4000).error.code, 'transcript-too-long');
  assert.equal(validateTranscriptInput({ transcript: 'ok' }, 4000).transcript, 'ok');
});

test('AI parses fenced and think-wrapped model output; rejects non-JSON', () => {
  const obj = extractJsonObject('<think>hmm</think>\n```json\n{"a":1}\n``` extra');
  assert.deepEqual(obj, { a: 1 });
  try {
    extractJsonObject('no json here');
    assert.fail('should throw');
  } catch (err) {
    assert.equal(err.code, 'invalid-model-json');
  }
  try {
    extractJsonObject('   ');
    assert.fail('should throw');
  } catch (err) {
    assert.equal(err.code, 'empty-model-response');
  }
});

test('AI validation confirms claims in-transcript and drops unconfirmed ones', () => {
  const transcript = 'Synthetic patient is awake, breathing normally, no severe bleeding, can walk.';
  const out = toValidatedExtraction({
    observations: { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' },
  }, transcript);
  assert.deepEqual(out.observations, { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' });
  assert.equal(out.evidence.breathing.toLowerCase(), 'breathing normally');
  assert.ok(out.uncertainties.some((u) => u.includes('verification')));
  assert.deepEqual(out.warnings, []);

  const bad = toValidatedExtraction({
    observations: { breathing: 'absent', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' },
  }, transcript);
  assert.equal(bad.observations.breathing, 'normal');
  assert.equal(bad.evidence.breathing, 'breathing normally');
  assert.ok(bad.warnings.some((w) => w.includes('breathing=normal')));
});

test('AI validation catches contradictions and negated phrases', () => {
  const mixed = toValidatedExtraction({
    observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'present', walking: 'unable' },
  }, 'Synthetic: no severe bleeding but the patient cannot walk.');
  assert.equal(mixed.observations.severeBleeding, 'absent');
  assert.equal(mixed.observations.walking, 'unable');
  assert.ok(mixed.warnings.length > 0);
});

test('Tagalog clitics inside a reported phrase still confirm the claim', () => {
  const transcript = 'may lalaki po dito around 69 years old, nahihirapan siyang huminga at masakit ang dibdib niya mga 30 minutes na';
  const out = toValidatedExtraction({
    observations: { breathing: 'abnormal', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' },
  }, transcript);
  assert.equal(out.observations.breathing, 'abnormal');
  assert.equal(out.evidence.breathing, 'nahihirapan siyang huminga');
  assert.ok(!out.uncertainties.includes('breathing was not clearly reported'));

  const walk = toValidatedExtraction({
    observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unable' },
  }, 'nasugatan at hindi po siya makalakad');
  assert.equal(walk.observations.walking, 'unable');
  assert.equal(walk.evidence.walking, 'hindi po siya makalakad');
});

test('explicit transcript phrases recover model misses while negation and conflicts stay unknown', () => {
  const transcript = 'May isang lalaki po dito, 69 years old. Nahihirapan siyang huminga at masakit ang dibdib niya. Gising siya at sumasagot. Walang pagdurugo at nakakalakad siya.';
  const out = toValidatedExtraction({
    observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' },
  }, transcript);
  assert.deepEqual(out.observations, { breathing: 'abnormal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' });
  assert.equal(out.evidence.breathing, 'Nahihirapan siyang huminga');
  assert.equal(out.evidence.consciousness, 'Gising');
  assert.equal(out.evidence.severeBleeding, 'Walang pagdurugo');
  assert.equal(out.evidence.walking, 'nakakalakad');
  assert.ok(!out.uncertainties.some((item) => /^(breathing|consciousness|severeBleeding|walking) was/.test(item)));

  const negated = toValidatedExtraction({
    observations: { breathing: 'abnormal', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' },
  }, 'Hindi po siya nahihirapan huminga.');
  assert.equal(negated.observations.breathing, 'unknown');

  const conflicting = toValidatedExtraction({
    observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' },
  }, 'Nahihirapan siyang huminga pero humihinga nang normal.');
  assert.equal(conflicting.observations.breathing, 'unknown');
  assert.ok(conflicting.warnings.some((item) => item.includes('Contradictory transcript phrases about breathing')));
});

test('a non-particle gap or an opposite statement still blocks confirmation', () => {
  const hard = toValidatedExtraction({
    observations: { breathing: 'abnormal', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' },
  }, 'hirap nang matinding huminga ang bata');
  assert.equal(hard.observations.breathing, 'unknown');
  assert.ok(hard.warnings.length > 0);

  const able = toValidatedExtraction({
    observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'able' },
  }, 'nasugatan at hindi po siya makalakad');
  assert.equal(able.observations.walking, 'unable');
});

test('AI validation coerces invented enums to unknown instead of failing', () => {
  const out = toValidatedExtraction({
    observations: { breathing: 'yes', consciousness: 'awake', severeBleeding: 'no', walking: 'sometimes' },
  }, 'Synthetic patient report without supported observations.');
  assert.deepEqual(out.observations, { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' });
  assert.ok(out.warnings.length >= 3);
});

// --- helpers: fake Ollama ----------------------------------------------------
function fakeOllama({ tags = ['qwen3:0.6b'], chat, status = 200, delayMs = 0, rawBody = null, digest = manifest.sha256, generatedTokens = 2, doneReason = 'stop' }) {
  const server = http.createServer((req, res) => {
    if (req.url === '/api/tags') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ models: tags.map((name) => ({ name })) }));
      return;
    }
    if (req.url === '/api/show') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ modelfile: `FROM /fixture/sha256-${digest}`, model_info: { 'general.architecture': 'qwen3' } }));
      return;
    }
    if (req.url === '/api/generate') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ model: 'qwen3:0.6b', done: true, done_reason: doneReason, eval_count: generatedTokens, response: 'fixture only' }));
      return;
    }
    if (req.url === '/api/chat') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const respond = () => {
          if (rawBody !== null) {
            res.writeHead(status, { 'Content-Type': 'application/json' });
            res.end(rawBody);
            return;
          }
          if (status !== 200) {
            res.writeHead(status, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'model not found' }));
            return;
          }
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ model: 'qwen3:0.6b', done: true, done_reason: 'stop', eval_count: 20, message: { content: chat } }));
        };
        if (delayMs) setTimeout(respond, delayMs);
        else respond();
      });
      return;
    }
    res.writeHead(404).end();
  });
  return server;
}

async function withAiApp(ollamaServer, fn) {
  ollamaServer.listen(0, '127.0.0.1');
  await once(ollamaServer, 'listening');
  const ollamaUrl = `http://127.0.0.1:${ollamaServer.address().port}`;
  const prev = { url: process.env.OLLAMA_URL, model: process.env.OLLAMA_MODEL, timeout: process.env.AI_TIMEOUT_MS, directory: process.env.QWEN_MODEL_DIR };
  process.env.QWEN_MODEL_DIR = fixtureDir;
  process.env.OLLAMA_URL = ollamaUrl;
  process.env.OLLAMA_MODEL = 'qwen3:0.6b';
  const appServer = createApp(openDb(':memory:')).listen(0, '127.0.0.1');
  await once(appServer, 'listening');
  const base = `http://127.0.0.1:${appServer.address().port}`;
  try {
    await fn(base);
  } finally {
    appServer.closeAllConnections();
    await new Promise((resolve) => appServer.close(resolve));
    ollamaServer.closeAllConnections();
    await new Promise((resolve) => ollamaServer.close(resolve));
    if (prev.url === undefined) delete process.env.OLLAMA_URL; else process.env.OLLAMA_URL = prev.url;
    if (prev.model === undefined) delete process.env.OLLAMA_MODEL; else process.env.OLLAMA_MODEL = prev.model;
    if (prev.directory === undefined) delete process.env.QWEN_MODEL_DIR; else process.env.QWEN_MODEL_DIR = prev.directory;
    if (prev.timeout === undefined) delete process.env.AI_TIMEOUT_MS; else process.env.AI_TIMEOUT_MS = prev.timeout;
  }
}

const GOOD_CHAT = JSON.stringify({
  observations: { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' },
});

// --- endpoint: mocked success ------------------------------------------------
test('AI extract returns validated processing + deterministic provisional triage (mocked Ollama)', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT }), async (base) => {
    const status = await (await fetch(`${base}/api/ai/status`)).json();
    assert.equal(status.ok, true);
    assert.equal(status.available, true);
    assert.equal(status.model, 'qwen3:0.6b');

    const res = await fetch(`${base}/api/ai/extract`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ transcript: TRANSCRIPT }),
    });
    assert.equal(res.status, 200);
    const data = await res.json();
    assert.equal(data.ok, true);
    assert.equal(data.processing.version, 1);
    assert.equal(data.processing.originalTranscript, TRANSCRIPT);
    assert.deepEqual(data.processing.observations, { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able', circulation: 'unknown' });
    assert.equal(data.processing.provenance.extraction.artifactSha256, manifest.sha256);
    assert.equal(data.processing.evidence.walking.source, 'model-inferred');
    assert.equal(data.provisional.triage, 'Minor'); // deterministic assessRisk, not the model
    assert.equal(data.provisional.requiresVerification, true);

    const assist = await (await fetch(`${base}/api/ai/triage-assist`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ transcript: TRANSCRIPT }),
    })).json();
    assert.equal(assist.ok, true);
    assert.equal(assist.draft.triage, 'Minor');
    assert.ok(assist.disclaimer);
  }));

test('AI extraction persists a complete evidence-backed report without assigning verified triage', () =>
  withAiApp(fakeOllama({ chat: JSON.stringify({ observations: {
    breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown',
  } }) }), async (base) => {
    const transcript = 'May isang lalaki po dito, 69 years old. Nahihirapan siyang huminga at masakit ang dibdib niya. Gising siya at sumasagot. Walang pagdurugo at nakakalakad siya mga 30 minutes na.';
    const extracted = await (await fetch(`${base}/api/ai/extract`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ transcript }),
    })).json();
    assert.equal(extracted.fields.symptomDuration, null);
    assert.deepEqual(extracted.fieldEvidence, {});
    assert.deepEqual(Object.keys(extracted.processing.observations), ['breathing', 'consciousness', 'severeBleeding', 'walking', 'circulation']);
    assert.ok(!extracted.processing.findings.some(finding => ['patient', 'incident', 'vital'].includes(finding.kind)));
    assert.ok(extracted.processing.findings.some((finding) => finding.name === 'Chest pain' && finding.excerpt === 'masakit ang dibdib'));
    assert.ok(!extracted.processing.findings.some((finding) => finding.name === 'Symptom duration'));
    assert.equal(extracted.provisional.triage, 'Immediate');

    const intake = await fetch(`${base}/api/sync-triage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ watchId: 'W-REPORT-TEST', reports: [{
        localId: 1, location: 'Unspecified', injuries: 'Unspecified', triage: 'Unassessed',
        patientCount: extracted.fields.patientCount, ageGroup: extracted.fields.ageGroup,
        etaMinutes: null, rawText: transcript, createdAt: '2026-10-10T00:00:00.000Z', processing: extracted.processing,
      }] }),
    });
    assert.deepEqual((await intake.json()).ackLocalIds, [1]);
    const rows = await (await fetch(`${base}/api/triage`)).json();
    assert.equal(rows[0].injuries, 'Unspecified', 'machine findings do not overwrite the reviewed legacy field');
    assert.equal(rows[0].effective_triage, 'Unassessed', 'machine observations remain unverified in the saved report');
    assert.ok(rows[0].processing.findings.some((finding) => finding.name === 'Chest pain'));
  }));

test('AI reports model-missing when Ollama lacks the configured model', () =>
  withAiApp(fakeOllama({ tags: ['other:1b'], chat: GOOD_CHAT }), async (base) => {
    const status = await (await fetch(`${base}/api/ai/status`)).json();
    assert.equal(status.available, false);
    assert.equal(status.error, 'model-missing');
  }));

test('AI extract surfaces invalid model JSON and schema violations as errors', () =>
  withAiApp(fakeOllama({ chat: 'not json at all' }), async (base) => {
    const res = await fetch(`${base}/api/ai/extract`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ transcript: TRANSCRIPT }),
    });
    assert.equal(res.status, 502);
    assert.equal((await res.json()).error, 'invalid-model-json');
  }));

test('AI extract rejects empty/invalid input with 400 and never calls inference', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT }), async (base) => {
    for (const body of [{}, { transcript: '' }, { transcript: 'a'.repeat(5000) }]) {
      const res = await fetch(`${base}/api/ai/extract`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      assert.equal(res.status, 400);
    }
  }));

test('AI status reports unreachable Ollama instead of hanging', async () => {
  const prev = process.env.OLLAMA_URL;
  process.env.OLLAMA_URL = 'http://127.0.0.1:9'; // closed port
  try {
    const s = await aiStatus(async () => { throw new Error('fetch failed'); });
    assert.equal(s.available, false);
    assert.equal(s.error, 'ollama-unreachable');
  } finally {
    if (prev === undefined) delete process.env.OLLAMA_URL; else process.env.OLLAMA_URL = prev;
  }
});

test('AI extract times out instead of waiting indefinitely', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT, delayMs: 1500 }), async (base) => {
    process.env.AI_TIMEOUT_MS = '200';
    const res = await fetch(`${base}/api/ai/extract`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ transcript: TRANSCRIPT }),
    });
    assert.equal(res.status, 504);
    assert.equal((await res.json()).error, 'ollama-timeout');
  }));

test('AI does not break existing report sync (regression)', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT }), async (base) => {
    const body = {
      watchId: 'W-AI-REG',
      reports: [{
        localId: 1, location: 'Barangay Arnaldo', injuries: 'Drowning, Unconscious',
        triage: 'Immediate', patientCount: 2, ageGroup: 'Child', etaMinutes: 10,
        rawText: 'Synthetic', createdAt: '2026-10-09T12:00:00.123Z',
      }],
    };
    const res = await (await fetch(`${base}/api/sync-triage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    })).json();
    assert.deepEqual(res.ackLocalIds, [1]);
    const rows = await (await fetch(`${base}/api/triage`)).json();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].triage, 'Immediate');
  }));

// --- live inference: runs only when a real Ollama is reachable ----------------
// Set LIVE_AI=0 to skip explicitly. Otherwise a skipped test is reported, never faked.
test('AI live inference against local Ollama (skipped when unavailable)', async (t) => {
  if (process.env.LIVE_AI === '0') return t.skip('LIVE_AI=0');
  const prev = { url: process.env.OLLAMA_URL, model: process.env.OLLAMA_MODEL };
  delete process.env.OLLAMA_URL;
  delete process.env.OLLAMA_MODEL;
  try {
    const s = await aiStatus();
    if (!s.available) return t.skip(`Ollama unavailable (${s.error})`);
    const { extractEmergency } = require('./ai');
    const out = await extractEmergency('Synthetic patient is unresponsive and not breathing.', { device: 'hospital-browser' });
    assert.equal(typeof out.processing.observations.breathing, 'string');
    assert.equal(out.processing.originalTranscript, 'Synthetic patient is unresponsive and not breathing.');
  } finally {
    if (prev.url === undefined) delete process.env.OLLAMA_URL; else process.env.OLLAMA_URL = prev.url;
    if (prev.model === undefined) delete process.env.OLLAMA_MODEL; else process.env.OLLAMA_MODEL = prev.model;
  }
});


test('execution-based health and exact tag matching (mocked runtime)', () =>
  withAiApp(fakeOllama({ tags: ['qwen3:0.6b-wrong'], chat: GOOD_CHAT }), async (base) => {
    assert.equal((await (await fetch(`${base}/api/ai/status`)).json()).available, false);
    const health = await (await fetch(`${base}/api/ai/health`)).json();
    assert.equal(health.status, 'ready');
    assert.equal(health.inference_available, true);
  }));

test('persisted extraction is idempotent and preserves original, encounter and correction history', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT }), async (base) => {
    const post = async (route, body) => {
      const response = await fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      return { status: response.status, data: await response.json() };
    };
    await post('/api/sync-triage', { watchId: 'SYNTHETIC-AI', reports: [{ localId: 1,
      location: 'Synthetic', injuries: 'Unspecified', triage: 'Unassessed', rawText: TRANSCRIPT,
      createdAt: '2026-10-09T00:00:00Z' }] });
    const [row] = await (await fetch(base + '/api/triage')).json();
    const input = { requestId: randomUUID(), baseRevision: 0 };
    const first = await post(`/api/triage/${row.id}/ai-extract`, input);
    assert.equal(first.status, 200);
    assert.equal(first.data.report.raw_text, TRANSCRIPT);
    assert.equal(first.data.report.current_transcript, TRANSCRIPT);
    assert.equal(first.data.report.encounter_id, row.encounter_id);
    assert.equal(first.data.report.computed_triage, 'Unassessed');
    assert.equal(first.data.report.processing.provenance.extraction.execution, 'local');
    const replay = await post(`/api/triage/${row.id}/ai-extract`, input);
    assert.equal(replay.data.report.history.length, 2);
    assert.equal(replay.data.replay, true);
    assert.equal((await post(`/api/triage/${row.id}/ai-extract`, { ...input, baseRevision: 1 })).status, 409);
    await post(`/api/triage/${row.id}/revisions`, { requestId: randomUUID(), baseRevision: 1,
      kind: 'correction', actor: 'Synthetic operator', reason: 'Synthetic correction', transcript: 'Synthetic corrected original' });
    const detail = await (await fetch(`${base}/api/triage/${row.id}`)).json();
    assert.equal(detail.raw_text, TRANSCRIPT);
    assert.equal(detail.processing, null);
    assert.equal(detail.history.length, 3);
    assert.equal((await post(`/api/triage/${row.id}/ai-extract`, { requestId: randomUUID(), baseRevision: 0 })).status, 409);
  }));

test('incomplete generated response is rejected and original persists', () =>
  withAiApp(fakeOllama({ rawBody: JSON.stringify({ model: 'qwen3:0.6b', message: { content: GOOD_CHAT }, done: false, eval_count: 0 }) }), async (base) => {
    const response = await fetch(base + '/api/ai/extract', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ transcript: TRANSCRIPT }) });
    assert.equal(response.status, 502);
    assert.equal((await response.json()).error, 'incomplete-model-response');
  }));


test('health rejects wrong weights, zero tokens and incomplete generation (mocked runtime)', async () => {
  await withAiApp(fakeOllama({ chat: GOOD_CHAT, digest: '0'.repeat(64) }), async (base) => {
    const response = await fetch(base + '/api/ai/health');
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error, 'model-identity-mismatch');
  });
  await withAiApp(fakeOllama({ chat: GOOD_CHAT, generatedTokens: 0 }), async (base) => {
    const response = await fetch(base + '/api/ai/health');
    assert.equal(response.status, 503);
    assert.equal((await response.json()).inference_available, false);
  });
  await withAiApp(fakeOllama({ doneReason: 'length' }), async (base) => {
    const response = await fetch(base + '/api/ai/health');
    assert.equal(response.status, 503);
    assert.equal((await response.json()).inference_available, false);
  });
});

test('concurrent extraction cannot overwrite a transcript correction', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT, delayMs: 200 }), async (base) => {
    const post = async (path, body) => fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    await post('/api/sync-triage', { watchId: 'SYNTHETIC-RACE', reports: [{ localId: 1, location: 'Synthetic',
      injuries: 'Unspecified', triage: 'Unassessed', rawText: TRANSCRIPT, createdAt: '2026-10-09T00:00:00Z' }] });
    const [row] = await (await fetch(base + '/api/triage')).json();
    const extraction = post(`/api/triage/${row.id}/ai-extract`, { requestId: randomUUID(), baseRevision: 0 });
    await new Promise(resolve => setTimeout(resolve, 50));
    const correction = await post(`/api/triage/${row.id}/revisions`, { requestId: randomUUID(), baseRevision: 0,
      actor: 'Synthetic', reason: 'Synthetic correction', kind: 'correction', transcript: 'Synthetic corrected' });
    assert.equal(correction.status, 200);
    assert.equal((await extraction).status, 409);
    const detail = await (await fetch(`${base}/api/triage/${row.id}`)).json();
    assert.equal(detail.current_transcript, 'Synthetic corrected');
    assert.equal(detail.processing, null);
    assert.equal(detail.raw_text, TRANSCRIPT);
  }));


test('invalid AI configuration returns an actionable error without stopping capture', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT }), async (base) => {
    process.env.AI_TIMEOUT_MS = '-1';
    const health = await (await fetch(base + '/api/ai/health')).json();
    assert.equal(health.state, 'ERROR');
    const response = await fetch(base + '/api/ai/extract', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ transcript: TRANSCRIPT }) });
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error, 'invalid-ai-config');
    assert.equal((await fetch(base + '/api/health')).status, 200);
  }));

test('shared v1 fixture is accepted without losing transcript/provenance', () => {
  const fixture = require('../docs/fixtures/ai-v1.json');
  const normalized = require('./processing').validateProcessing(fixture.processing);
  assert.equal(normalized.error, undefined);
  assert.equal(normalized.value.originalTranscript, fixture.processing.originalTranscript);
  assert.deepEqual(normalized.value.provenance, fixture.processing.provenance);
  assert.deepEqual(normalized.value.evidence, fixture.processing.evidence);
});

test('five-field extraction quote-grounds radial pulse and preserves RAG without demographic extraction', () =>
  withAiApp(fakeOllama({ chat: GOOD_CHAT }), async (base) => {
    for (const [pulse, expected] of [
      ['Radial pulse present.', 'present'], ['No palpable radial pulse.', 'absent'],
      ['Radial pulse present but radial pulse absent.', 'unknown'], ['Not radial pulse present.', 'unknown'],
      ['Pulse present.', 'unknown'],
    ]) {
      const transcript = `Synthetic patient: awake, breathing normally, no bleeding, can walk. Chest pain. 60 years old, Barangay Uno, ETA 10 minutes. ${pulse}`;
      const result = await (await fetch(`${base}/api/ai/extract`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ transcript }) })).json();
      assert.equal(result.processing.observations.circulation, expected);
      assert.equal(result.fields.location, null);
      assert.equal(result.fields.patientCount, null);
      assert.equal(result.fields.ageGroup, 'Unspecified');
      assert.equal(result.fields.etaMinutes, null);
      assert.ok(result.processing.findings.every(f => ['observation', 'symptom'].includes(f.kind)));
      assert.ok(result.retrieval.matches.length, 'RAG output is retained');
      assert.equal(result.provisional.triage, 'Minor', 'circulation introduces no scoring rule');
    }
  }));
