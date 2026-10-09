const test = require('node:test');
const assert = require('node:assert/strict');
const { openDb } = require('./db');
const { ingestBatch } = require('./sync');
const { createApp } = require('./server');
const { cloudConfig, createCloudSync } = require('./cloud');

const env = {
  SUPABASE_URL: 'https://example.supabase.co/',
  SUPABASE_ANON_KEY: 'sb_publishable_synthetic',
  SUPABASE_HUB_EMAIL: 'hub@example.test',
  SUPABASE_HUB_PASSWORD: 'synthetic-password',
};
const jwt = (claims) => `e30.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.sig`;
const report = (localId, over = {}) => ({ localId, location: 'Synthetic pickup', injuries: 'Severe bleeding',
  triage: 'Immediate', rawText: `Synthetic transcript ${localId}`, createdAt: `2026-10-09T00:00:0${localId}.000Z`, ...over });

/** Fake Supabase: records requests; `upsert(rows)` decides each upload reply. */
function fakeSupabase(upsert = (rows) => ({ status: 201, body: rows.map(({ report_id }) => ({ report_id })) })) {
  const calls = [];
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, headers: init.headers, body });
    if (url.includes('/auth/v1/token')) {
      return Response.json({ access_token: 'synthetic-token', expires_in: 3600, user: { id: 'hub-user' } });
    }
    const { status, body: reply } = upsert(body);
    return Response.json(reply, { status });
  };
  return { calls, fetch, uploads: () => calls.filter((call) => call.url.includes('/rest/v1/')) };
}

function setup(t, fake, reports = [report(1), report(2)]) {
  const db = openDb(':memory:');
  t.after(() => db.close());
  ingestBatch(db, 'W-CLOUD', reports);
  const logs = [];
  const cloud = createCloudSync(db, { config: cloudConfig(env), fetch: fake.fetch, log: (line) => logs.push(line) });
  return { db, cloud, logs, rows: () => db.prepare('SELECT * FROM cloud_sync ORDER BY report_id').all() };
}

test('cloud configuration requires all hub values, HTTPS and a publishable key', () => {
  assert.equal(cloudConfig({}).error, 'Cloud sync is not configured');
  assert.equal(cloudConfig({ ...env, SUPABASE_HUB_PASSWORD: '', SUPABASE_HUB_EMAIL: ' ' }).error,
    'Cloud sync needs SUPABASE_HUB_EMAIL, SUPABASE_HUB_PASSWORD in .env');
  assert.match(cloudConfig({ ...env, SUPABASE_HUB_EMAIL: '<hub-account-email>' }).error, /placeholder/);
  assert.equal(cloudConfig({ ...env, SUPABASE_URL: 'http://example.supabase.co' }).error, 'SUPABASE_URL must use HTTPS');
  for (const key of ['sb_secret_synthetic', jwt({ role: 'service_role' })]) {
    assert.match(cloudConfig({ ...env, SUPABASE_ANON_KEY: key }).error, /not a secret/);
  }
  const ok = cloudConfig({ ...env, SUPABASE_ANON_KEY: jwt({ role: 'anon' }) });
  assert.equal(ok.error, null);
  assert.equal(ok.url, 'https://example.supabase.co');
});

test('disabled cloud sync never calls the network and leaves reports local', async (t) => {
  const fake = fakeSupabase();
  const db = openDb(':memory:');
  t.after(() => db.close());
  ingestBatch(db, 'W-CLOUD', [report(1)]);
  const cloud = createCloudSync(db, { config: cloudConfig({}), fetch: fake.fetch, log: () => {} });
  const status = await cloud.syncNow();
  assert.equal(fake.calls.length, 0);
  assert.equal(status.state, 'disabled');
  assert.equal(status.pending, 1);
});

test('uploads source reports as the hub user and marks only acknowledged UUIDs', async (t) => {
  const fake = fakeSupabase();
  const { cloud, rows, logs } = setup(t, fake);
  const status = await cloud.syncNow();
  assert.deepEqual({ state: status.state, pending: status.pending, synced: status.synced }, { state: 'ok', pending: 0, synced: 2 });
  const [signIn, upload] = fake.calls;
  assert.equal(signIn.url, 'https://example.supabase.co/auth/v1/token?grant_type=password');
  assert.deepEqual(signIn.body, { email: env.SUPABASE_HUB_EMAIL, password: env.SUPABASE_HUB_PASSWORD });
  assert.equal(upload.headers.Authorization, 'Bearer synthetic-token');
  assert.equal(upload.headers.apikey, env.SUPABASE_ANON_KEY);
  assert.match(upload.url, /on_conflict=report_id/);
  assert.deepEqual(Object.keys(upload.body[0]).sort(), ['age_group', 'created_at', 'eta_minutes', 'injuries', 'location',
    'patient_count', 'raw_text', 'report_id', 'triage', 'watch_id']);
  assert.equal(upload.body[0].raw_text, 'Synthetic transcript 1');
  assert.ok(rows().every((row) => row.synced_at && row.owner_id === 'hub-user'));
  assert.deepEqual(upload.body.map((row) => row.report_id), rows().map((row) => row.cloud_report_id));
  await cloud.syncNow();
  assert.equal(fake.uploads().length, 1, 'Synced reports are not uploaded again');
  assert.ok(!JSON.stringify([status, logs]).includes('synthetic-password'));
  assert.ok(!JSON.stringify([status, logs]).includes('synthetic-token'));
});

test('offline and partial acknowledgments keep reports queued with the same UUID', async (t) => {
  let mode = 'offline';
  const fake = fakeSupabase((rows) => ({ status: 201, body: rows.slice(0, mode === 'partial' ? 1 : rows.length)
    .map(({ report_id }) => ({ report_id })) }));
  const fetch = (url, init) => (mode === 'offline' ? Promise.reject(new TypeError('fetch failed')) : fake.fetch(url, init));
  const db = openDb(':memory:');
  t.after(() => db.close());
  ingestBatch(db, 'W-CLOUD', [report(1), report(2)]);
  const cloud = createCloudSync(db, { config: cloudConfig(env), fetch, log: () => {} });

  let status = await cloud.syncNow();
  assert.equal(status.state, 'error');
  assert.match(status.message, /unreachable/);
  assert.equal(status.pending, 2);
  const queued = db.prepare('SELECT cloud_report_id FROM cloud_sync ORDER BY report_id').all();

  mode = 'partial';
  status = await cloud.syncNow();
  assert.deepEqual({ state: status.state, pending: status.pending, synced: status.synced }, { state: 'error', pending: 1, synced: 1 });
  assert.match(status.message, /acknowledged 1 of 2/);

  mode = 'online';
  status = await cloud.syncNow();
  assert.deepEqual({ state: status.state, pending: status.pending, synced: status.synced }, { state: 'ok', pending: 0, synced: 2 });
  assert.deepEqual(db.prepare('SELECT cloud_report_id FROM cloud_sync ORDER BY report_id').all(), queued);
  assert.deepEqual(fake.uploads().at(-1).body.map((row) => row.report_id), [queued[1].cloud_report_id]);
});

test('a rejected report is isolated and its error omits row details', async (t) => {
  let bad = 'Synthetic transcript 2';
  const fake = fakeSupabase((rows) => (rows.some((row) => row.raw_text === bad)
    ? { status: 400, body: { code: '23514', message: 'new row violates check constraint', details: 'Failing row contains (Synthetic transcript 2)' } }
    : { status: 201, body: rows.map(({ report_id }) => ({ report_id })) }));
  const { cloud, rows } = setup(t, fake);
  let status = await cloud.syncNow();
  assert.deepEqual({ state: status.state, synced: status.synced, rejected: status.rejected, pending: status.pending },
    { state: 'ok', synced: 1, rejected: 1, pending: 0 });
  const rejected = rows().find((row) => row.rejected_reason);
  assert.equal(rejected.rejected_reason, 'Supabase upload failed (HTTP 400): new row violates check constraint');
  assert.equal(rejected.synced_at, null);
  bad = null;
  status = await cloud.syncNow();
  assert.equal(status.rejected, 1, 'Automatic retries skip rejected rows');
  status = await cloud.syncNow({ retryRejected: true });
  assert.deepEqual({ synced: status.synced, rejected: status.rejected }, { synced: 2, rejected: 0 });
});

test('sign-in and server failures keep every report queued', async (t) => {
  const db = openDb(':memory:');
  t.after(() => db.close());
  ingestBatch(db, 'W-CLOUD', [report(1)]);
  const fetch = async (url) => (url.includes('/auth/')
    ? Response.json({ error_description: 'Invalid login credentials' }, { status: 400 })
    : assert.fail('No upload without a session'));
  const cloud = createCloudSync(db, { config: cloudConfig(env), fetch, log: () => {} });
  const status = await cloud.syncNow();
  assert.equal(status.message, 'Supabase hub sign-in failed (HTTP 400): Invalid login credentials');
  assert.deepEqual({ pending: status.pending, rejected: status.rejected }, { pending: 1, rejected: 0 });
});

test('dashboard API exposes cloud status and manual sync without Supabase credentials', async (t) => {
  const db = openDb(':memory:');
  const fake = fakeSupabase();
  const cloud = createCloudSync(db, { config: cloudConfig(env), fetch: fake.fetch, log: () => {} });
  const server = createApp(db, { cloud }).listen(0, '127.0.0.1');
  t.after(() => { server.close(); db.close(); });
  await new Promise((resolve) => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  await fetch(`${base}/api/sync-triage`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ watchId: 'W-CLOUD', reports: [report(1)] }) });
  const before = await (await fetch(`${base}/api/cloud/status`)).json();
  assert.deepEqual({ ok: before.ok, configured: before.configured, pending: before.pending }, { ok: true, configured: true, pending: 1 });
  const after = await (await fetch(`${base}/api/cloud/sync`, { method: 'POST' })).json();
  assert.deepEqual({ state: after.state, synced: after.synced, pending: after.pending }, { state: 'ok', synced: 1, pending: 0 });
  assert.ok(!JSON.stringify([before, after]).match(/synthetic-(password|token)|sb_publishable/));

  const localDb = openDb(':memory:');
  const local = createApp(localDb, { cloud: createCloudSync(localDb, { config: cloudConfig({}), log: () => {} }) })
    .listen(0, '127.0.0.1');
  t.after(() => { local.close(); localDb.close(); });
  await new Promise((resolve) => local.once('listening', resolve));
  const disabled = await (await fetch(`http://127.0.0.1:${local.address().port}/api/cloud/status`)).json();
  assert.deepEqual({ configured: disabled.configured, state: disabled.state }, { configured: false, state: 'disabled' });
});
