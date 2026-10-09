// Synthetic acceptance only: cloned sources, empty volumes, no existing hub/data.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { execFileSync } = require('node:child_process');

async function check() {
  const source = path.resolve(__dirname, '..');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-connectivity-'));
  const project = 'vanguard-connectivity-' + randomUUID().slice(0, 8);
  const env = { ...process.env, HUB_PORT: '0', VITE_PORT: '0', HUB_USERS: '', HUB_BIND_ADDRESS: '127.0.0.1', SUPABASE_URL: '', SUPABASE_ANON_KEY: '', SUPABASE_HUB_EMAIL: '', SUPABASE_HUB_PASSWORD: '' };
  const compose = (...args) => execFileSync('docker', ['compose', '-p', project, ...args], { cwd: directory, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  let started = false;
  try {
    for (const folder of ['hub', 'models', 'docs']) fs.cpSync(path.join(source, folder), path.join(directory, folder), {
      recursive: true, filter: file => !['node_modules', 'dist', 'data'].includes(path.basename(file)) && !file.endsWith('.gguf'),
    });
    fs.copyFileSync(path.join(source, 'compose.yaml'), path.join(directory, 'compose.yaml'));
    fs.mkdirSync(path.join(directory, 'hub/data'));
    // Teammate without Git LFS: only a pointer, never cached real weights.
    fs.writeFileSync(path.join(directory, 'models/qwen3-0.6b/qwen3-0.6b-q4_k_m.gguf'), 'version https://git-lfs.github.com/spec/v1\n');
    started = true;
    // Registry pulls intermittently time out on fresh runners; converge with retries.
    for (let attempt = 1; ; attempt++) {
      try { compose('up', '-d', '--build'); break; }
      catch (error) {
        if (attempt === 3) throw error;
        console.error(`compose up attempt ${attempt} failed; retrying after cleanup`);
        try { compose('down', '--remove-orphans'); } catch {}
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, attempt * 5000);
      }
    }
    const base = 'http://' + compose('port', 'frontend', '3301').trim();
    const get = async route => {
      const response = await fetch(base + route, { signal: AbortSignal.timeout(130000) });
      assert.equal(response.status, 200, route); return response.json();
    };
    const readiness = async () => {
      for (let attempt = 0; attempt < 12; attempt++) {
        try { const health = await get('/api/ai/health'); assert.equal(health.state, 'READY'); assert.equal(health.inference_available, true); return health; }
        catch (error) { if (attempt === 11) throw error; await new Promise(resolve => setTimeout(resolve, 1000)); }
      }
    };
    await readiness();
    const post = async (route, body, requestId = randomUUID()) => {
      const response = await fetch(base + route, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Request-ID': requestId },
        body: JSON.stringify(body), signal: AbortSignal.timeout(130000) });
      assert.equal(response.status, 200, route);
      assert.equal(response.headers.get('X-Request-ID'), requestId);
      return response.json();
    };
    const transcripts = ['Synthetic A is awake and can walk.', 'Synthetic B is unresponsive and cannot walk.'];
    const outputs = await Promise.all(transcripts.map(transcript => post('/api/ai/extract', { transcript })));
    for (let index = 0; index < outputs.length; index++) {
      assert.equal(outputs[index].contractVersion, 1);
      assert.equal(outputs[index].processing.originalTranscript, transcripts[index]);
      assert.equal(outputs[index].processing.provenance.extraction.artifactSha256, require('../models/qwen3-0.6b/manifest.json').sha256);
    }
    assert.notEqual(outputs[0].requestId, outputs[1].requestId);
    const reports = outputs.map((output, index) => ({ localId: index + 1, reportId: randomUUID(), encounterId: randomUUID(),
      createdAt: new Date().toISOString(), rawText: transcripts[index], processing: output.processing,
      triage: 'Unassessed', location: 'Synthetic', injuries: 'Unspecified', patientCount: null }));
    const envelopes = reports.map((report, index) => ({ watchId: `QA-${project}-${index}`, reports: [report] }));
    const receipts = await Promise.all(envelopes.map(body => post('/api/sync-triage', body)));
    assert.deepEqual(receipts.map(receipt => receipt.ackLocalIds), [[1], [2]]);
    await Promise.all(envelopes.map(body => post('/api/sync-triage', body)));
    const before = await get('/api/triage'); assert.equal(before.length, 2);
    assert.ok(before.every(row => row.effective_triage === 'Unassessed'));
    await require(path.join(directory, 'hub/qa/hmr-check.cjs')).check(base);
    compose('stop', 'ollama');
    const unavailable = await (await fetch(base + '/api/ai/health')).json();
    assert.equal(unavailable.inference_available, false);
    assert.equal((await get('/api/triage')).length, 2);
    compose('up', '-d', '--force-recreate', 'ollama', 'hub');
    await readiness();
    assert.deepEqual(await get('/api/triage'), before);
    // Runtime container cannot depend on external services after provisioning.
    compose('exec', '-T', 'ollama', 'sh', '-c', 'test -s /root/.ollama/models/blobs/sha256-ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a');
    const runtime = compose('ps', '-q', 'ollama').trim();
    const hubImage = execFileSync('docker', ['inspect', '--format', '{{.Image}}', compose('ps', '-q', 'hub').trim()], { encoding: 'utf8' }).trim();
    execFileSync('docker', ['run', '--rm', '--network', `container:${runtime}`, '--entrypoint', 'node', hubImage, '-e',
      "require('node:assert/strict').rejects(fetch('https://1.1.1.1', {signal: AbortSignal.timeout(3000)})).catch(() => { process.exitCode = 1; })"], { stdio: 'pipe' });
    console.log(JSON.stringify({ result: 'PASS', project, checks: ['LFS-pointer fresh clone', 'automatic pinned download/import', 'real Qwen tokens',
      'Vite same-origin proxy and HMR', 'concurrent request isolation', 'shared contract', 'provisional SQLite persistence',
      'duplicate ACKs', 'runtime disconnect', 'container recreation and model/report retention', 'runtime external egress denied'] }, null, 2));
  } catch (error) {
    if (started) {
      try { console.error(compose('logs', '--no-color', '--tail', '25', 'model-init', 'hub')); } catch {}
    }
    throw error;
  } finally {
    if (started) compose('down', '--volumes', '--remove-orphans');
    fs.rmSync(directory, { recursive: true, force: true });
  }
}
if (require.main === module) check().catch(error => { console.error(error.message); process.exitCode = 1; });
module.exports = { check };
