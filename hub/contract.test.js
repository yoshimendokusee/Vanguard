const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { once } = require('node:events');
const { openDb } = require('./db');
const { createApp } = require('./server');

test('documented LAN example works end to end with the shipped dashboard', async () => {
  const contract = fs.readFileSync(path.join(__dirname, '../docs/api-contract.md'), 'utf8');
  const examples = [...contract.matchAll(/```json\n([\s\S]*?)\n```/g)].map((m) => JSON.parse(m[1]));
  const [request, expected] = examples;
  assert.ok(request.watchId && Array.isArray(request.reports));
  const db = openDb(':memory:');
  const server = createApp(db).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await (await fetch(`${base}/api/health`)).json()).ok, true);
    assert.equal(typeof (await (await fetch(`${base}/api/config`)).json()).hospital, 'string');
    const post = () => fetch(`${base}/api/sync-triage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request),
    });
    const response = await post();
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), expected);
    assert.equal((await (await post()).json()).duplicates, request.reports.length);
    const rows = await (await fetch(`${base}/api/triage`)).json();
    assert.equal(rows.length, request.reports.length);
    for (const [wire, stored] of Object.entries({
      location: 'location', injuries: 'injuries', triage: 'triage', patientCount: 'patient_count',
      ageGroup: 'age_group', etaMinutes: 'eta_minutes', rawText: 'raw_text', createdAt: 'created_at',
    })) assert.equal(rows[0][stored], request.reports[0][wire]);
    const status = await fetch(`${base}/api/triage/${rows[0].id}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ status: 'arrived' }),
    });
    assert.equal(status.status, 200);
    assert.equal((await (await fetch(`${base}/api/triage`)).json())[0].status, 'arrived');
    const events = await fetch(`${base}/api/events`);
    assert.match(events.headers.get('content-type'), /text\/event-stream/);
    await events.body.cancel();
    const page = await fetch(base);
    assert.equal(page.status, 200);
    const html = await page.text();
    assert.equal(html, fs.readFileSync(path.join(__dirname, 'public/index.html'), 'utf8'));
    const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
    assert.ok(scripts.length > 0);
    for (const [index, script] of scripts.entries()) new vm.Script(script[1], { filename: `dashboard-${index}.js` });
    const parser = fs.readFileSync(path.join(__dirname, '../watch/lib/nlp/triage_parser.dart'), 'utf8');
    const categories = [...parser.matchAll(/static const (?:immediate|delayed|minor|deceased|unassessed) = '([^']+)'/g)].map((m) => m[1]);
    for (const category of categories) assert.ok(html.includes(`'${category}'`), `Dashboard missing ${category}`);
    const sender = fs.readFileSync(path.join(__dirname, '../watch/lib/services/sync_service.dart'), 'utf8');
    assert.ok(sender.includes('/api/sync-triage'));
    for (const field of Object.keys(request.reports[0])) assert.ok(sender.includes(`'${field}'`), `Watch sender missing ${field}`);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    db.close();
  }
});

test('reopening a populated hub database preserves reports, status and deduplication', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'vanguard-reopen-'));
  const file = path.join(temp, 'hub.db');
  let db;
  try {
    db = openDb(file);
    const { ingestBatch } = require('./sync');
    const contract = fs.readFileSync(path.join(__dirname, '../docs/api-contract.md'), 'utf8');
    const request = JSON.parse(contract.match(/```json\n([\s\S]*?)\n```/)[1]);
    ingestBatch(db, request.watchId, request.reports);
    db.prepare("UPDATE triage_reports SET status = 'arrived'").run();
    const before = db.prepare('SELECT * FROM triage_reports').all();
    db.close();
    db = openDb(file);
    assert.deepEqual(db.prepare('SELECT * FROM triage_reports').all(), before);
    assert.deepEqual(ingestBatch(db, request.watchId, request.reports).ackLocalIds, [1]);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM triage_reports').get().count, 1);
  } finally {
    if (db?.open) db.close();
    fs.rmSync(temp, { recursive: true, force: true });
  }
});
