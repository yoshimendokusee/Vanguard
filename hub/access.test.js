const test = require('node:test');
const assert = require('node:assert/strict');
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
  const send = (device, token) => fetch(base + '/api/sync-triage', { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ watchId: device, reports: [{ localId: 1, createdAt: '2026-10-10T00:00:00Z',
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
