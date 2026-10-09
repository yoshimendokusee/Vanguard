const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { extractEmergency } = require('../ai');
const { openDb } = require('../db');
const { createApp } = require('../server');

// Synthetic model artifact: the real GGUF is never read and no real inference runs.
const artifact = Buffer.from('GGUF synthetic RAG integration fixture');
const fixtureDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-rag-test-'));
const manifest = { ...require('../../models/qwen3-0.6b/manifest.json'), file: 'fixture.gguf',
  sizeBytes: artifact.length, sha256: createHash('sha256').update(artifact).digest('hex') };
fs.writeFileSync(path.join(fixtureDir, manifest.file), artifact);
fs.writeFileSync(path.join(fixtureDir, 'manifest.json'), JSON.stringify(manifest));
test.after(() => fs.rmSync(fixtureDir, { recursive: true, force: true }));

const TAGLISH = 'Nahihilo ako at sumasakit ang dibdib ko. Hindi makalakad, nahulog sa motor, walang helmet.';

/** Fake local Ollama that records every chat request the hub sends. */
function fakeOllama(modelAnswer) {
  const chats = [];
  const server = http.createServer((req, res) => {
    const json = (body) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
    if (req.url === '/api/show') {
      return json({ modelfile: `FROM /fixture/sha256-${manifest.sha256}`, model_info: { 'general.architecture': 'qwen3' } });
    }
    if (req.url === '/api/chat') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        chats.push(JSON.parse(body));
        json({ model: 'qwen3:0.6b', done: true, done_reason: 'stop', eval_count: 12, message: { content: JSON.stringify(modelAnswer) } });
      });
      return;
    }
    res.writeHead(404).end();
  });
  return { server, chats };
}

async function withOllama(modelAnswer, fn) {
  const { server, chats } = fakeOllama(modelAnswer);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const saved = { url: process.env.OLLAMA_URL, model: process.env.OLLAMA_MODEL, dir: process.env.QWEN_MODEL_DIR, rag: process.env.RAG_ENABLED };
  process.env.OLLAMA_URL = `http://127.0.0.1:${server.address().port}`;
  process.env.OLLAMA_MODEL = 'qwen3:0.6b';
  process.env.QWEN_MODEL_DIR = fixtureDir;
  try { await fn(chats); } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    for (const [key, value] of [['OLLAMA_URL', saved.url], ['OLLAMA_MODEL', saved.model], ['QWEN_MODEL_DIR', saved.dir], ['RAG_ENABLED', saved.rag]]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
}

const userMessage = (chat) => chat.messages.find((m) => m.role === 'user').content;

test('retrieval puts matched terms in the prompt and the response, with the draft label', () =>
  withOllama({ observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unable' } }, async (chats) => {
    delete process.env.RAG_ENABLED;
    const result = await extractEmergency(TAGLISH);
    const prompt = userMessage(chats[0]);
    assert.match(prompt, /Reference glossary/);
    assert.match(prompt, /sumasakit ang dibdib = Chest pain/);
    assert.match(prompt, /not patient evidence/);
    assert.ok(result.retrieval.matches.some((m) => m.id === 'chest-pain'));
    assert.equal(result.retrieval.reviewStatus, 'unreviewed-draft');
    assert.equal(result.promptVersion, 'vanguard-extract-v2');
    // The original transcript is sent untouched and stays the stored original.
    assert.ok(prompt.includes(TAGLISH));
    assert.equal(result.processing.originalTranscript, TAGLISH);
  }));

test('the glossary never changes findings or provisional triage', () =>
  withOllama({ observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unable' } }, async () => {
    delete process.env.RAG_ENABLED;
    const withRag = await extractEmergency(TAGLISH);
    process.env.RAG_ENABLED = '0';
    const withoutRag = await extractEmergency(TAGLISH);
    assert.ok(withRag.retrieval.matches.length > 0);
    assert.equal(withoutRag.retrieval, null);
    assert.deepEqual(withRag.processing.observations, withoutRag.processing.observations);
    assert.deepEqual(withRag.processing.evidence, withoutRag.processing.evidence);
    assert.deepEqual(withRag.provisional, withoutRag.provisional);
  }));

test('a glossary meaning cannot launder a model claim into a finding', () =>
  // "Mabilis huminga" is glossary-mapped to "Rapid breathing", but the transcript
  // contains no confirmed breathing phrase, so the model's claim must still be dropped.
  withOllama({ observations: { breathing: 'abnormal', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' } }, async (chats) => {
    delete process.env.RAG_ENABLED;
    const result = await extractEmergency('Mabilis huminga ang bata.');
    assert.match(userMessage(chats[0]), /mabilis huminga = Rapid breathing/);
    assert.equal(result.processing.observations.breathing, 'unknown');
    assert.ok(result.warnings.some((w) => /breathing/.test(w)));
    assert.equal(result.provisional.triage, 'Unassessed');
  }));

test('RAG_ENABLED=0 sends no glossary and the lookup route reports it unavailable', () =>
  withOllama({ observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' } }, async (chats) => {
    process.env.RAG_ENABLED = '0';
    const result = await extractEmergency(TAGLISH);
    assert.doesNotMatch(userMessage(chats[0]), /Reference glossary/);
    assert.equal(result.retrieval, null);

    const server = createApp(openDb(':memory:')).listen(0, '127.0.0.1');
    await once(server, 'listening');
    try {
      const res = await fetch(`http://127.0.0.1:${server.address().port}/api/knowledge/lookup`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ transcript: TAGLISH }) });
      assert.equal(res.status, 503);
      assert.equal((await res.json()).error, 'knowledge-unavailable');
    } finally {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  }));

test('an invalid or missing knowledge pack disables retrieval without breaking extraction', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-rag-bad-'));
  try {
    const bad = path.join(dir, 'bad.json');
    // A pack that tries to attach urgency to a term must be refused whole.
    fs.writeFileSync(bad, JSON.stringify({ packId: 'x', packVersion: '1', reviewStatus: 'unreviewed-draft',
      entries: [{ id: 'a', phrases: ['sakit'], filipino: 'a', english: 'a', medicalTerm: 'a', category: 'symptom', triage: 'Immediate' }] }));
    const script = `const { glossaryFor } = require('./ai');
      const out = glossaryFor('sakit ang dibdib');
      process.stdout.write(JSON.stringify({ matches: out.matches, retrieval: out.retrieval }));`;
    for (const file of [bad, path.join(dir, 'missing.json')]) {
      const stdout = execFileSync(process.execPath, ['-e', script], { cwd: path.join(__dirname, '..'),
        env: { ...process.env, RAG_KNOWLEDGE_FILE: file }, encoding: 'utf8' });
      const lines = stdout.trim().split('\n');
      // The hub logs why retrieval is off (reason only, never pack or patient text).
      assert.match(lines[0], /^\[rag\] disabled: /);
      assert.deepEqual(JSON.parse(lines[lines.length - 1]), { matches: [], retrieval: null }, file);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('denied terms and duplicate phrases are kept out of the prompt but still reported', () =>
  withOllama({ observations: { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' } }, async (chats) => {
    delete process.env.RAG_ENABLED;
    const result = await extractEmergency('Awake, breathing normally, no severe bleeding, can walk.');
    const prompt = userMessage(chats[0]);
    assert.doesNotMatch(prompt, /severe bleeding =/i);
    assert.match(prompt, /breathing normally = Breathing normally/);
    assert.equal(result.retrieval.matches.filter((m) => m.matched === 'severe bleeding').every((m) => m.negated), true);
    assert.ok(result.retrieval.matches.some((m) => m.matched === 'severe bleeding'));
    // Findings remain grounded in the transcript and unchanged by the glossary.
    assert.equal(result.processing.observations.severeBleeding, 'absent');
    assert.equal(result.provisional.triage, 'Minor');
  }));

test('the pipeline retains RAG terms while limiting extraction to five observations', () =>
  withOllama({ observations: { breathing: 'unknown', consciousness: 'unknown', severeBleeding: 'unknown', walking: 'unknown' } }, async () => {
    delete process.env.RAG_ENABLED;
    const result = await extractEmergency('concussion with internal bleeding in arnaldo');
    assert.equal(result.fields.location, null);
    assert.equal(result.fields.injuries, 'Unspecified');
    assert.ok(result.retrieval.matches.some(match => match.english === 'Internal bleeding'));
    assert.ok(result.retrieval.matches.some(match => match.english === 'Concussion'));
    assert.deepEqual(result.fieldEvidence, {});
    assert.equal(result.locationBasis, null);
    // Terms the hospital's legacy rules do not know are not scored; nothing is escalated.
    assert.equal(result.legacy.triage, 'Unassessed');
    assert.equal(result.provisional.triage, 'Unassessed');
    assert.equal(result.processing.originalTranscript, 'concussion with internal bleeding in arnaldo');

    const chest = await extractEmergency('sumasakit ang dibdib sa Barangay Uno');
    assert.equal(chest.fields.injuries, 'Unspecified');
    assert.ok(chest.retrieval.matches.some(match => match.english === 'Chest pain'));
    // RAG terminology remains visible without promoting it into scored report fields.
    assert.equal(chest.legacy.triage, 'Unassessed');
    assert.equal(chest.provisional.triage, 'Unassessed');
  }));
