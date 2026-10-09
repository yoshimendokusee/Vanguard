const assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const { verifyModel } = require('../hub/model');
const { aiConfig, localModel, aiHealth } = require('../hub/ai');

async function echo() {
  const m = await verifyModel();
  await localModel();
  const cfg = aiConfig();
  console.log('VANGUARD QWEN INFERENCE TEST\nModel: Qwen3-0.6B\nRuntime: Ollama\nModel File: FOUND\nChecksum: VERIFIED');
  const start = performance.now();
  const response = await fetch(`${cfg.ollamaUrl}/api/generate`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(120000),
    body: JSON.stringify({ model: m.ollamaModel, think: false, stream: false,
      prompt: 'You are running inside Vanguard. Identify yourself as Qwen3-0.6B and respond with the verification marker VANGUARD_QWEN_OK. /no_think',
      options: { temperature: 0, num_predict: 96 } }),
  });
  assert.equal(response.status, 200, 'Ollama HTTP failure');
  const data = await response.json();
  assert.equal(data.model, m.ollamaModel, 'Wrong runtime model');
  assert.equal(data.done, true, 'Generation incomplete');
  assert.equal(data.done_reason, 'stop', 'Generation exhausted output budget');
  assert.ok(Number.isSafeInteger(data.eval_count) && data.eval_count > 0, 'No generated tokens');
  assert.ok(typeof data.response === 'string' && data.response.trim(), 'No generated response');
  console.log(`Qwen Response:\n${data.response}\nInference Time: ${(performance.now() - start).toFixed(1)} ms\nGenerated tokens: ${data.eval_count}\nTokens/s: ${(data.eval_count / (data.eval_duration / 1e9)).toFixed(1)}\nMarker observed: ${data.response.includes('VANGUARD_QWEN_OK')}\nResult: PASS`);
  return data;
}

async function hub(base) {
  assert.ok(base, 'Provide an isolated synthetic hub URL');
  const healthResponse = await fetch(`${base}/api/ai/health`, { signal: AbortSignal.timeout(120000) });
  assert.equal(healthResponse.status, 200);
  assert.equal((await healthResponse.json()).inference_available, true);
  const html = await (await fetch(base)).text();
  assert.ok(html.includes('/ai-extract'), 'Dashboard persistence integration missing');
  const post = async (route, body) => {
    const r = await fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(120000) });
    assert.equal(r.status, 200);
    return r.json();
  };
  const { randomUUID } = require('node:crypto');
  const original = 'Synthetic patient is awake, breathing normally, no severe bleeding, can walk.';
  const reportId = randomUUID(), encounterId = randomUUID();
  const intake = await post('/api/sync-triage', { watchId: 'QWEN-SYNTHETIC-VERIFY', reports: [{ localId: 1,
    reportId, encounterId, createdAt: new Date().toISOString(), location: 'Synthetic verification',
    injuries: 'Unspecified', triage: 'Unassessed', rawText: original }] });
  assert.deepEqual(intake.ackLocalIds, [1]);
  const rows = await (await fetch(base + '/api/triage')).json();
  const row = rows.find(r => r.source_report_id === reportId);
  assert.ok(row);
  const request = { requestId: randomUUID(), baseRevision: row.revision };
  const result = await post(`/api/triage/${row.id}/ai-extract`, request);
  assert.equal(result.report.raw_text, original);
  assert.equal(result.report.encounter_id, encounterId);
  assert.equal(result.report.processing.provenance.extraction.artifactSha256, (await verifyModel()).sha256);
  assert.equal(result.report.effective_triage, 'Unassessed');
  const replay = await post(`/api/triage/${row.id}/ai-extract`, request);
  assert.equal(replay.replay, true);
  assert.equal(replay.report.history.length, 2);
  console.log(JSON.stringify({ result: 'PASS', reportId, checks: ['real hub generation', 'SQLite original/provenance', 'explicit encounter', 'idempotent extraction', 'dashboard route present'] }));
}

if (require.main === module) {
  const mode = process.argv[2];
  const job = mode === 'echo' ? echo() : mode === 'hub' ? hub(process.argv[3]) : aiHealth().then(result => { console.log(result); assert.equal(result.status, 'ready'); });
  job.catch(error => { console.error('FAIL:', error.code || error.message); process.exitCode = 1; });
}
module.exports = { echo, hub };
