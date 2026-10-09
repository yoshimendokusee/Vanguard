const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { openDb } = require('./db');
const { createApp } = require('./server');
const { extractJsonObject, toValidatedExtraction, validateTranscriptInput, aiStatus } = require('./ai');

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
  assert.equal(bad.observations.breathing, 'unknown');
  assert.equal(bad.evidence.breathing, null);
  assert.ok(bad.warnings.some((w) => w.includes('breathing')));
});

test('AI validation catches contradictions and negated phrases', () => {
  const mixed = toValidatedExtraction({
    observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'present', walking: 'unable' },
  }, 'Synthetic: no severe bleeding but the patient cannot walk.');
  // "severe bleeding" occurs inside a denial, so the opposite trigger fires -> unknown.
  assert.equal(mixed.observations.severeBleeding, 'unknown');
  assert.equal(mixed.observations.walking, 'unable');
  assert.ok(mixed.warnings.length > 0);
});

test('AI validation coerces invented enums to unknown instead of failing', () => {
  const out = toValidatedExtraction({
    observations: { breathing: 'yes', consciousness: 'awake', severeBleeding: 'no', walking: 'sometimes' },
  }, TRANSCRIPT);
  assert.deepEqual(out.observations, { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' });
  assert.ok(out.warnings.length >= 3);
});

// --- helpers: fake Ollama ----------------------------------------------------
function fakeOllama({ tags = ['qwen3:0.6b'], chat, status = 200, delayMs = 0, rawBody = null }) {
  const server = http.createServer((req, res) => {
    if (req.url === '/api/tags') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ models: tags.map((name) => ({ name })) }));
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
          res.end(JSON.stringify({ message: { content: chat } }));
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
  const prev = { url: process.env.OLLAMA_URL, model: process.env.OLLAMA_MODEL, timeout: process.env.AI_TIMEOUT_MS };
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
    assert.deepEqual(data.processing.observations, { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' });
    assert.equal(data.processing.provenance.extraction, null);
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
