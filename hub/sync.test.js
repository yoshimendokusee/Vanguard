const test = require('node:test');
const assert = require('node:assert');
const { openDb } = require('./db');
const { createApp } = require('./server');

const report = (over = {}) => ({
  localId: 1,
  location: 'Barangay Arnaldo',
  injuries: 'Drowning, Unconscious',
  triage: 'Immediate',
  patientCount: 2,
  ageGroup: 'Child',
  etaMinutes: 10,
  rawText: 'Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, sampung minuto.',
  createdAt: '2026-10-09T12:00:00.123Z',
  ...over,
});

async function withServer(fn) {
  const server = createApp(openDb(':memory:')).listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (body) =>
    fetch(`${base}/api/sync-triage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  const list = () => fetch(`${base}/api/triage`).then((r) => r.json());
  const setStatus = (id, status) =>
    fetch(`${base}/api/triage/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ status }),
    });
  try {
    await fn({ base, post, list, setStatus });
  } finally {
    server.close();
  }
}

test('inserts a batch, stores every field, acks every local id', () =>
  withServer(async ({ post, list }) => {
    const res = await post({
      watchId: 'W-1',
      reports: [report(), report({ localId: 2, createdAt: '2026-10-09T12:00:05.000Z' })],
    });
    assert.deepStrictEqual(res.ackLocalIds, [1, 2]);
    assert.strictEqual(res.inserted, 2);
    const [row] = await list();
    assert.strictEqual(row.triage, 'Immediate');
    assert.strictEqual(row.patient_count, 2);
    assert.strictEqual(row.age_group, 'Child');
    assert.strictEqual(row.eta_minutes, 10);
    assert.strictEqual(row.injuries, 'Drowning, Unconscious');
    assert.strictEqual(row.status, 'inbound');
  }));

test('syncing the same batch twice does not double-count casualties', () =>
  withServer(async ({ post, list }) => {
    const body = { watchId: 'W-1', reports: [report()] };
    await post(body);
    const second = await post(body);
    assert.strictEqual(second.inserted, 0);
    assert.strictEqual(second.duplicates, 1);
    assert.deepStrictEqual(second.ackLocalIds, [1]); // still acked so the watch clears it
    assert.strictEqual((await list()).length, 1);
  }));

test('same timestamp from a different watch is NOT a duplicate', () =>
  withServer(async ({ post, list }) => {
    await post({ watchId: 'W-1', reports: [report()] });
    await post({ watchId: 'W-2', reports: [report()] });
    assert.strictEqual((await list()).length, 2);
  }));

test('timestamp formatting cannot dodge the duplicate check', () =>
  withServer(async ({ post, list }) => {
    await post({ watchId: 'W-1', reports: [report({ createdAt: '2026-10-09T12:00:00.100Z' })] });
    await post({ watchId: 'W-1', reports: [report({ createdAt: '2026-10-09T12:00:00.1Z' })] });
    assert.strictEqual((await list()).length, 1);
  }));

test('invalid reports are rejected and not acked', () =>
  withServer(async ({ post, list }) => {
    const res = await post({
      watchId: 'W-1',
      reports: [
        report({ localId: 7, triage: 'Meh' }),
        report({ localId: 8, createdAt: 'nope' }),
        report({ localId: 9, patientCount: 0 }),
        report({ localId: 10, etaMinutes: -5 }),
        report({ localId: 11, ageGroup: 'Teen' }),
      ],
    });
    assert.strictEqual(res.rejected.length, 5);
    assert.deepStrictEqual(res.ackLocalIds, []);
    assert.strictEqual((await list()).length, 0);
  }));

test('optional fields default sensibly', () =>
  withServer(async ({ post, list }) => {
    const r = report();
    delete r.patientCount;
    delete r.ageGroup;
    r.etaMinutes = null;
    await post({ watchId: 'W-1', reports: [r] });
    const [row] = await list();
    assert.strictEqual(row.patient_count, 1);
    assert.strictEqual(row.age_group, 'Unspecified');
    assert.strictEqual(row.eta_minutes, null);
  }));

test('ED ordering: acuity, then soonest ETA; arrived patients sink', () =>
  withServer(async ({ post, list, setStatus }) => {
    const t = (s) => `2026-10-09T12:00:${s}.000Z`;
    await post({
      watchId: 'W-1',
      reports: [
        report({ localId: 1, triage: 'Minor', injuries: 'Abrasion', etaMinutes: 5, createdAt: t('01') }),
        report({ localId: 2, triage: 'Deceased', injuries: 'Deceased', etaMinutes: 5, createdAt: t('02') }),
        report({ localId: 3, triage: 'Delayed', injuries: 'Fracture', etaMinutes: 5, createdAt: t('03') }),
        report({ localId: 4, triage: 'Unassessed', injuries: 'Unspecified', etaMinutes: null, createdAt: t('04') }),
        report({ localId: 5, triage: 'Immediate', etaMinutes: 30, createdAt: t('05') }),
        report({ localId: 6, triage: 'Immediate', etaMinutes: 10, createdAt: t('06') }),
        report({ localId: 7, triage: 'Immediate', etaMinutes: null, createdAt: t('07') }),
      ],
    });
    const order = async () => (await list()).map((r) => r.eta_minutes + ':' + r.effective_triage);
    assert.deepStrictEqual(await order(), [
      '10:Immediate',
      '30:Immediate',
      'null:Immediate', // unknown ETA after known ETAs
      '5:Unassessed', // reported death requires qualified confirmation
      'null:Unassessed',
      '5:Delayed',
      '5:Minor',
    ]);

    const [first] = await list();
    assert.strictEqual((await setStatus(first.id, 'arrived')).status, 200);
    const after = await list();
    assert.strictEqual(after[after.length - 1].id, first.id);
    assert.strictEqual(after[after.length - 1].status, 'arrived');
    assert.strictEqual((await setStatus(first.id, 'bogus')).status, 400);
    assert.strictEqual((await setStatus(99999, 'arrived')).status, 404);
  }));
