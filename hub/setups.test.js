const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
const { loadKnowledge } = require('./rag/knowledge');
const { openDb } = require('./db');
const { createApp } = require('./server');

const file = path.join(__dirname, 'public', 'setups.json');
const draft = JSON.parse(fs.readFileSync(file, 'utf8'));
const index = loadKnowledge();
const names = new Set([...index.byId.values()].map((e) => e.english));

// Resource and team labels only. Anything outside this list needs a deliberate, reviewed addition.
const ALLOWED_TAGS = new Set(['Active cooling', 'Active warming', 'Airway + warming', 'Animal bite service', 'Antivenom', 'Blood / OR', 'Burn care',
  'CT / neurosurgery', 'Cardiac monitor', 'Decontamination', 'ECG / cardiology', 'Eye / ENT', 'Glucose check', 'Haemostasis', 'IV fluids', 'Isolation room',
  'Mental health / safety watch', 'Neuro obs', 'OB / delivery', 'Oxygen / airway', 'Paediatrics', 'Poison control / toxicology', 'Protection services',
  'Resus bay', 'Spinal precautions', 'Stroke team / CT', 'Surgical team', 'Suturing', 'Trauma team', 'Wound care', 'X-ray / ortho']);

test('draft setups are labelled unreviewed and every key is an exact pack term', () => {
  assert.equal(draft.status, 'unreviewed-draft');
  assert.match(draft.note, /NOT been reviewed/);
  assert.ok(Object.keys(draft.setups).length >= 100);
  // The saved injuries text uses the pack's English names, so a key must match one exactly.
  const unknown = Object.keys(draft.setups).filter((key) => !names.has(key));
  assert.deepEqual(unknown, []);
});

test('setups are resource labels from a fixed list, with no treatment, dose or urgency', () => {
  const used = new Set();
  for (const [term, tags] of Object.entries(draft.setups)) {
    assert.ok(Array.isArray(tags) && tags.length >= 1 && tags.length <= 3, term);
    for (const tag of tags) {
      assert.ok(ALLOWED_TAGS.has(tag), `${term}: unexpected setup "${tag}"`);
      assert.doesNotMatch(tag, /\b(give|administer|dose|dosage|\d+\s?mg|urgent|immediate|priority|triage|drug)\b/i, tag);
      used.add(tag);
    }
  }
  assert.deepEqual([...used].sort(), [...draft.tags].sort(), 'tags list matches what is used');
});

test('common emergencies each get a setup', () => {
  for (const term of ['Concussion', 'Internal bleeding', 'Motorcycle crash', 'Heart attack', 'Stroke', 'Poisoning', 'Childbirth', 'Gunshot wound', 'Tuberculosis', 'Suicide attempt']) {
    assert.ok(draft.setups[term], term);
  }
});

test('the board serves the draft file and loads it without being required', async () => {
  const server = createApp(openDb(':memory:')).listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/setups.json`);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).status, 'unreviewed-draft');
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
  const dashboard = fs.readFileSync(path.join(__dirname, 'public', 'dashboard.js'), 'utf8');
  assert.match(dashboard, /fetch\('\/setups\.json'\)[\s\S]*\.catch\(\(\) => \{\}\)\.finally\(load\)/, 'a missing file must not stop the board loading');
  assert.match(dashboard, /const prepFor = \(label\) => \(PREP\[label\] \?/, "the hospital's own mapping wins over the draft");
});

test('new acute terms have setups, with sensible resources', () => {
  const expected = { 'Gunshot to chest': 'Blood / OR', 'Facial burns': 'Oxygen / airway', 'Baby crowning': 'OB / delivery', 'Pulled from water': 'Airway + warming',
    'Suspected stroke': 'Stroke team / CT', 'Swallowed pesticide': 'Poison control / toxicology', 'Baby not breathing': 'Resus bay', 'Violent outburst': 'Mental health / safety watch' };
  for (const [term, tag] of Object.entries(expected)) assert.ok(draft.setups[term].includes(tag), `${term} -> ${tag}`);
  assert.ok(Object.keys(draft.setups).length >= 450);
});
