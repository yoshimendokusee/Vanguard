const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { assessRisk, RULE_VERSION } = require('./risk');

// Shared with the native Apple triage port (watch/apple TriageParityTests). The fixture holds
// every valid observation combination, so a rule change here must be mirrored in Swift.
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, '../docs/fixtures/triage-parity-v1.json'), 'utf8'));

test('triage parity fixture matches the hub rules for every observation combination', () => {
  assert.equal(fixture.ruleVersion, RULE_VERSION);
  assert.equal(fixture.cases.length, 4 * 3 * 3 * 3, 'fixture must cover all combinations');
  const seen = new Set();
  for (const item of fixture.cases) {
    seen.add(JSON.stringify(item.observations));
    assert.deepEqual(assessRisk(item.observations), item.expected, JSON.stringify(item.observations));
  }
  assert.equal(seen.size, fixture.cases.length, 'no duplicate combinations');
});

test('unknown never becomes Minor and a critical finding is always Immediate', () => {
  for (const item of fixture.cases) {
    const o = item.observations;
    const critical = ['abnormal', 'absent'].includes(o.breathing) || o.consciousness === 'unresponsive' || o.severeBleeding === 'present';
    if (critical) assert.equal(item.expected.triage, 'Immediate');
    if (item.expected.triage === 'Minor') {
      assert.deepEqual(o, { breathing: 'normal', consciousness: 'alert', severeBleeding: 'absent', walking: 'able' });
    }
  }
});
