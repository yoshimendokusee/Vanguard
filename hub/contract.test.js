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
  const examples = [...contract.matchAll(/```json\r?\n([\s\S]*?)\r?\n```/g)].map((m) => JSON.parse(m[1]));
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
    const dashboard = fs.existsSync(path.join(__dirname, 'dist/index.html')) ? 'dist' : 'public';
    assert.equal(html, fs.readFileSync(path.join(__dirname, dashboard, 'index.html'), 'utf8'));
    assert.ok(!html.includes('/@vite/client'), 'Express must serve the production page without Vite');
    const assets = [...html.matchAll(/(?:src|href)="(\/[^"]+\.(?:js|css))"/g)];
    assert.ok(assets.length >= 2, 'Dashboard must load JavaScript and CSS');
    for (const asset of assets) assert.equal((await fetch(base + asset[1])).status, 200);
    const source = fs.readFileSync(path.join(__dirname, 'public/dashboard.js'), 'utf8');
    new vm.Script(source.replace(/^import .*;\r?\n/gm, ''), { filename: 'dashboard.js' });
    const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script\s*>/gi)];
    assert.ok(scripts.length > 0);
    for (const [index, script] of scripts.entries()) new vm.Script(script[1], { filename: `dashboard-${index}.js` });
    const parser = fs.readFileSync(path.join(__dirname, '../watch/lib/nlp/triage_parser.dart'), 'utf8');
    const categories = [...parser.matchAll(/static const (?:immediate|delayed|minor|deceased|unassessed) = '([^']+)'/g)].map((m) => m[1]);
    for (const category of categories) assert.ok(source.includes(`'${category}'`), `Dashboard missing ${category}`);
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
    const request = JSON.parse(contract.match(/```json\r?\n([\s\S]*?)\r?\n```/)[1]);
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

test('dashboard priority keeps an urgent unknown ETA ahead of a sooner minor report', () => {
  const html = fs.readFileSync(path.join(__dirname, 'public/dashboard.js'), 'utf8');
  const category = html.match(/  const category = .*;/)[0];
  const rank = html.match(/  const RANK = .*;/)[0];
  const select = html.match(/  function priorityPatient\(list\) \{[\s\S]*?\n  \}/)[0];
  const pick = vm.runInNewContext(`${category}\n${rank}\n${select}\npriorityPatient`, {
    etaAt: (row) => row.eta_minutes === null ? null : row.eta_minutes,
  });
  const minor = { id: 1, triage: 'Minor', effective_triage: 'Minor', eta_minutes: 1 };
  const urgent = { id: 2, triage: 'Minor', effective_triage: 'Immediate', eta_minutes: null };
  assert.equal(pick([minor, urgent]).id, urgent.id);
  assert.equal(urgent.triage, 'Minor', 'Original category must remain intact');
});

test('dashboard excludes unknown counts and invalidated findings from readiness suggestions', () => {
  const html = fs.readFileSync(path.join(__dirname, 'public/dashboard.js'), 'utf8');
  const count = html.match(/  const countOf = .*;/)[0];
  const sum = html.match(/  const patients = .*;/)[0];
  const checkCounts = vm.runInNewContext(`${count}\n${sum}\npatients`, {});
  assert.equal(checkCounts([{ patient_count: 1, patient_count_known: false }, { patient_count: 2, patient_count_known: true }]), 2);
  const readiness = html.match(/  const readyItems = \(r\) => \{[\s\S]*?\n  \};/)[0];
  const checkReadiness = vm.runInNewContext(`${readiness}\nreadyItems`, { needsOf: () => ['Blood / OR'] });
  assert.equal(checkReadiness({ source_findings_current: false, age_group: 'Child' }).length, 0);
  assert.equal(checkReadiness({ source_findings_current: true, age_group: 'Child' }).length, 2);
});

test('draft setup suggestions are read-only, explain themselves, and never feed readiness', () => {
  const html = fs.readFileSync(path.join(__dirname, 'public/dashboard.js'), 'utf8');
  const suggested = html.match(/  const suggestedOf = \(r\) => \{[\s\S]*?\n  \};/)[0];
  const prep = { Concussion: ['CT / neurosurgery', 'Neuro obs'], 'Head injury': ['CT / neurosurgery'], Dizziness: [] };
  const suggestedOf = vm.runInNewContext(`${suggested}\nsuggestedOf`, {
    labelsOf: (r) => r.injuries.split(',').map((s) => s.trim()), prepFor: (label) => prep[label] || [], Map, Set });
  const list = (r) => JSON.stringify(suggestedOf(r)); // vm arrays have another realm's prototype
  const aiSaved = { source_findings_current: false, processing: { version: 1 }, current_transcript: 'a', raw_text: 'a',
    injuries: 'Concussion, Head injury, Dizziness', age_group: 'Adult' };
  assert.equal(list(aiSaved), JSON.stringify([{ setup: 'CT / neurosurgery', because: ['Concussion', 'Head injury'] }, { setup: 'Neuro obs', because: ['Concussion'] }]));
  assert.equal(list({ ...aiSaved, age_group: 'Child' }).includes('"setup":"Paediatrics","because":["age group Child"]'), true);
  assert.equal(list({ ...aiSaved, current_transcript: 'corrected' }), '[]', 'corrected transcript invalidates the saved terms');
  assert.equal(list({ ...aiSaved, processing: null }), '[]', 'invalidated without AI processing stays empty');
  assert.equal(list({ ...aiSaved, source_findings_current: true }), '[]', 'current findings use the normal checklist');
  const readiness = html.match(/  const readyItems = \(r\) => \{[\s\S]*?\n  \};/)[0];
  assert.doesNotMatch(readiness, /suggestedOf/, 'suggestions must not enter readiness items or counts');
});

test('dashboard extraction displays five observations and retains RAG without filling patient details', () => {
  const source = fs.readFileSync(path.join(__dirname, 'public/dashboard.js'), 'utf8');
  assert.match(source, /circulation: 'Circulation'/);
  assert.match(source, /Radial pulse present/);
  assert.match(source, /data\.retrieval && data\.retrieval\.matches/);
  assert.ok(!source.includes('applyExtractedFields'));
  assert.ok(!source.includes('renderDashboard'));
  assert.ok(!source.includes('Alex Hunter'));
});
