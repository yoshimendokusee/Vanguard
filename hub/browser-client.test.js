const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');

test('browser outbox survives restart, validates scoped receipts and separates accounts', async () => {
  const values = new Map([['vanguard-access-token', 'fixture-only']]);
  const storage = { get length() { return values.size; }, key: index => [...values.keys()][index],
    getItem: key => values.get(key) || null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
  let user = 'operator-a', receipt = [99], bodies = [];
  const create = () => {
    const window = {};
    const context = { window, crypto: webcrypto, Headers, AbortSignal, localStorage: storage, sessionStorage: storage,
      fetch: async (route, options) => {
        assert.match(route, /^\/api\//);
        assert.ok(options.headers.get('X-Request-ID'));
        if (route === '/api/config') return Response.json({ user: { id: user } });
        bodies.push(JSON.parse(options.body));
        return Response.json({ ok: true, ackLocalIds: receipt, rejected: [] });
      } };
    vm.runInNewContext(fs.readFileSync(__dirname + '/public/hub-client.js', 'utf8'), context);
    return window.VanguardApi;
  };
  const report = { localId: 1, reportId: 'synthetic-original', rawText: 'Synthetic exact original', createdAt: '2026-10-10T00:00:00Z' };
  const client = create();
  await client.retain(report);
  await assert.rejects(client.flush(), /no valid hospital receipt/);
  const restarted = create();
  assert.equal((await restarted.pending())[0].rawText, report.rawText);
  user = 'operator-b'; values.set('vanguard-owner', user);
  assert.equal((await create().pending()).length, 0);
  user = 'operator-a'; values.set('vanguard-owner', user); receipt = [1];
  await restarted.flush();
  assert.equal((await restarted.pending()).length, 0);
  assert.equal(bodies[0].watchId, bodies[1].watchId);
  assert.equal(bodies[0].reports[0].createdAt, bodies[1].reports[0].createdAt);
  await Promise.all([client.retain({ ...report, reportId: 'second' }), restarted.retain({ ...report, reportId: 'third' })]);
  assert.equal((await restarted.pending()).length, 2, 'Concurrent captures must not replace each other');
  await assert.rejects(client.request('http://ollama:11434/api/chat'), /same-origin/);
});

test('browser saves before inference and retains originals on a crossed response', async () => {
  const values = new Map();
  const storage = { get length() { return values.size; }, key: index => [...values.keys()][index],
    getItem: key => values.get(key) || null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
  const window = {};
  const report = { reportId: 'synthetic-capture', localId: 7, rawText: 'Synthetic unchanged original', createdAt: '2026-10-10T00:00:00Z', triage: 'Unassessed' };
  let crossed = false;
  const context = { window, crypto: webcrypto, Headers, AbortSignal, localStorage: storage, sessionStorage: storage,
    fetch: async (route, options) => {
      assert.equal(route, '/api/ai/extract');
      const saved = JSON.parse([...values.entries()].find(([key]) => key.endsWith('/' + report.reportId))[1]);
      assert.equal(saved.rawText, report.rawText);
      assert.equal(saved.readyToSend, false, 'Persist original before any model call');
      const fixture = JSON.parse(fs.readFileSync(__dirname + '/../docs/fixtures/ai-v1.json'));
      fixture.requestId = options.headers.get('X-Request-ID');
      fixture.processing.originalTranscript = crossed ? 'Another session' : report.rawText;
      return Response.json(fixture, { headers: { 'X-Request-ID': fixture.requestId } });
    } };
  vm.runInNewContext(fs.readFileSync(__dirname + '/public/hub-client.js', 'utf8'), context);
  const api = window.VanguardApi;
  await api.prepare(report);
  assert.equal((await api.pending())[0].processing.originalTranscript, report.rawText);
  crossed = true;
  await assert.rejects(api.prepare(report), /Invalid inference response/);
  const retained = (await api.pending())[0];
  assert.equal(retained.rawText, report.rawText);
  assert.equal(retained.readyToSend, true);
  assert.equal(retained.processing, undefined, 'Never attach another session response');
});
