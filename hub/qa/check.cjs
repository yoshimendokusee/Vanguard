const assert = require('node:assert/strict');

async function check(base = 'http://127.0.0.1:3000') {
  const watchId = 'W-SYNTHETIC-QA';
  const reports = ['Abrasion', 'Unspecified', 'Severe bleeding', 'Fracture'].map((injuries, index) => ({
    localId: index + 1, injuries, triage: 'Minor', location: 'Synthetic pickup', rawText: 'Synthetic QA only',
    patientCount: 1, ageGroup: 'Unspecified', etaMinutes: 10, createdAt: `2026-10-09T00:00:0${index}.000Z`,
  }));
  const send = async (batch) => {
    const response = await fetch(`${base}/api/sync-triage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ watchId, reports: batch }),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  assert.equal((await (await fetch(`${base}/api/health`)).json()).ok, true);
  const before = (await (await fetch(`${base}/api/triage`)).json()).filter((row) => row.watch_id === watchId);
  if (process.argv.includes('--expect-existing')) assert.equal(before.length, 4, 'Persistent synthetic rows missing after restart');
  const first = await send(reports);
  assert.equal(first.inserted + first.duplicates, 4);
  assert.deepEqual(first.ackLocalIds, [1, 2, 3, 4]);
  const replay = await send(reports);
  assert.equal(replay.inserted, 0);
  assert.equal(replay.duplicates, 4);
  const conflict = await send([{ ...reports[0], rawText: 'Different synthetic original' }]);
  assert.deepEqual(conflict.ackLocalIds, []);
  assert.match(conflict.rejected[0].reason, /identity conflict/);
  const rows = (await (await fetch(`${base}/api/triage`)).json()).filter((row) => row.watch_id === watchId);
  assert.equal(rows.length, 4);
  assert.deepEqual(rows.map((row) => row.effective_triage), ['Immediate', 'Unassessed', 'Delayed', 'Minor']);
  assert.ok(rows.every((row) => row.requires_verification && row.risk_reason));
  return { result: 'PASS', checks: ['HTTP receipt', 'provisional priority', 'duplicates', 'conflicting identity',
    ...(process.argv.includes('--expect-existing') ? ['SQLite restart persistence'] : [])],
    time: new Date().toISOString() };
}

if (require.main === module) {
  check().then((result) => console.log(JSON.stringify(result)))
    .catch((error) => { console.error(JSON.stringify({ result: 'FAIL', error: error.message })); process.exitCode = 1; });
}
module.exports = { check };
