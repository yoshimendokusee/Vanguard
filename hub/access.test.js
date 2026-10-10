const test = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { once } = require('node:events');
const { createApp } = require('./server');
const { openDb } = require('./db');
const { hubAccess, validateLanAccess } = require('./access');

test('assigned credentials isolate device intake and protect hospital records', async () => {
  const previous = process.env.HUB_USERS;
  process.env.HUB_USERS = JSON.stringify([
    { id: 'user-a', role: 'device', token: 'a'.repeat(32), watchIds: ['WATCH-A'] },
    { id: 'user-b', role: 'device', token: 'b'.repeat(32), watchIds: ['WATCH-B'] },
    { id: 'hospital-operator', role: 'operator', token: 'c'.repeat(32) },
  ]);
  const db = openDb(':memory:');
  const server = createApp(db).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const sourceIds = { 'WATCH-A': randomUUID(), 'WATCH-B': randomUUID() };
  const send = (device, token) => fetch(base + '/api/sync-triage', { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ watchId: device, reports: [{ localId: 1, reportId: sourceIds[device], createdAt: '2026-10-10T00:00:00Z',
      rawText: `Synthetic ${device}`, triage: 'Unassessed', location: 'Synthetic', injuries: 'Unspecified' }] }) });
  try {
    const denied = await fetch(base + '/api/triage');
    assert.equal(denied.status, 401);
    assert.match(denied.headers.get('X-Request-ID'), /^[a-f0-9-]{36}$/);
    const [a, b] = await Promise.all([send('WATCH-A', 'a'.repeat(32)), send('WATCH-B', 'b'.repeat(32))]);
    assert.equal(a.status, 200); assert.equal(b.status, 200);
    assert.notEqual(a.headers.get('X-Request-ID'), b.headers.get('X-Request-ID'));
    assert.deepEqual((await a.json()).ackLocalIds, [1]);
    assert.equal((await send('WATCH-A', 'b'.repeat(32))).status, 403);
    assert.equal((await fetch(base + '/api/triage', { headers: { Authorization: `Bearer ${'a'.repeat(32)}` } })).status, 403);
    const rows = await (await fetch(base + '/api/triage', { headers: { Authorization: `Bearer ${'c'.repeat(32)}` } })).json();
    assert.equal(rows.length, 2);
    assert.deepEqual(rows.map(row => row.raw_text).sort(), ['Synthetic WATCH-A', 'Synthetic WATCH-B']);
    assert.equal((await send('WATCH-A', 'a'.repeat(32))).status, 200);
    assert.equal(db.prepare('SELECT COUNT(*) AS count FROM triage_reports').get().count, 2);
    const deviceHeaders = { Authorization: `Bearer ${'a'.repeat(32)}`, 'Content-Type': 'application/json' };
    const own = await (await fetch(base + '/api/triage/source/' + sourceIds['WATCH-A'], { headers: deviceHeaders })).json();
    assert.equal(own.watch_id, 'WATCH-A');
    assert.equal(own.encounter, undefined, 'device history does not expose hospital patient records');
    assert.equal((await fetch(base + '/api/triage/source/' + sourceIds['WATCH-B'], { headers: deviceHeaders })).status, 403);
    const edit = { requestId: randomUUID(), baseRevision: 0, actor: 'self', reason: 'Synthetic correction', kind: 'correction', transcript: 'Synthetic corrected A' };
    const correct = (id, body) => fetch(base + `/api/triage/${id}/revisions`, { method: 'POST', headers: deviceHeaders, body: JSON.stringify(body) });
    assert.equal((await correct(own.id, edit)).status, 200);
    assert.equal((await correct(own.id, edit)).status, 200, 'the same correction retries idempotently');
    assert.equal((await correct(own.id, { ...edit, requestId: randomUUID() })).status, 409, 'stale corrections cannot overwrite');
    assert.equal((await correct(own.id, { requestId: randomUUID(), baseRevision: 1, actor: 'self', reason: 'Synthetic', kind: 'override', override: 'Minor' })).status, 403);
    const other = rows.find(row => row.watch_id === 'WATCH-B');
    assert.equal((await correct(other.id, edit)).status, 403);
    assert.equal((await fetch(base + '/api/events')).status, 401);
  } finally {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); db.close();
    if (previous === undefined) delete process.env.HUB_USERS; else process.env.HUB_USERS = previous;
  }
});

test('invalid credentials and unauthenticated LAN binding fail before startup', () => {
  assert.throws(() => hubAccess('[{"id":"bad","role":"operator","token":"short"}]'));
  const previous = process.env.HUB_BIND_ADDRESS, previousHost = process.env.HOST, previousUsers = process.env.HUB_USERS;
  process.env.HUB_BIND_ADDRESS = '0.0.0.0';
  process.env.HOST = '0.0.0.0';
  try {
    for (const users of ['', '[]']) { process.env.HUB_USERS = users; assert.throws(validateLanAccess, /requires HUB_USERS/); }
  } finally {
    for (const [key, value] of Object.entries({ HUB_BIND_ADDRESS: previous, HOST: previousHost, HUB_USERS: previousUsers })) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
});

test('operator enrollment issues a single-use device credential that can sync', async () => {
  const previous = process.env.HUB_USERS;
  process.env.HUB_USERS = JSON.stringify([{ id: 'hospital-operator', role: 'operator', token: 'c'.repeat(32) }]);
  const db = openDb(':memory:');
  const server = createApp(db).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  const headers = { Authorization: `Bearer ${'c'.repeat(32)}` };
  try {
    const created = await (await fetch(base + '/api/enrollment/codes', { method: 'POST', headers })).json();
    assert.equal(created.ok, true);
    assert.match(created.code, /^[A-F0-9]{16}$/);
    assert.match(created.qrText, /^VANGUARD-ENROLL:/);
    assert.equal(created.token, undefined, 'the dashboard receives no permanent device token');

    const watchId = 'APPLE-WATCH-ENROLLED';
    const redeemed = await fetch(base + '/api/enrollment/redeem', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: created.code, watchId }) });
    const credential = await redeemed.json();
    assert.equal(redeemed.status, 200);
    assert.equal(credential.ok, true);
    assert.ok(credential.token.length >= 32);
    assert.equal((await fetch(base + '/api/enrollment/redeem', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: created.code, watchId: 'APPLE-WATCH-SECOND' }) })).status, 400);

    const sync = await fetch(base + '/api/sync-triage', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${credential.token}` },
      body: JSON.stringify({ watchId, reports: [] }) });
    assert.equal(sync.status, 200);
  } finally {
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); db.close();
    if (previous === undefined) delete process.env.HUB_USERS; else process.env.HUB_USERS = previous;
  }
});
