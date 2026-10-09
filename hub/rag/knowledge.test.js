const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { loadKnowledge, buildIndex, retrieve, validatePack, normalize, packInfo } = require('./knowledge');
const { glossaryNote, callOllama, toValidatedExtraction } = require('../ai');
const { openDb } = require('../db');
const { createApp } = require('../server');

const index = loadKnowledge();
const ids = (text) => retrieve(index, text).map((m) => m.id);

test('shipped pack loads, is flagged as an unreviewed draft and carries no clinical fields', () => {
  const info = packInfo(index);
  assert.equal(info.reviewStatus, 'unreviewed-draft');
  assert.ok(info.entryCount >= 10);
  for (const entry of index.byId.values()) {
    assert.deepEqual(Object.keys(entry).sort(), ['category', 'english', 'filipino', 'id', 'medicalTerm', 'phrases']);
  }
});

test('retrieves Filipino symptom phrases from a Taglish statement', () => {
  const found = retrieve(index, 'Nahihilo ako at sumasakit ang dibdib ko.');
  assert.deepEqual(found.map((m) => m.id).sort(), ['chest-pain', 'dizziness']);
  assert.equal(found.find((m) => m.id === 'chest-pain').english, 'Chest pain');
  assert.equal(found.find((m) => m.id === 'dizziness').medicalTerm, 'Dizziness');
});

test('matching ignores case, punctuation and diacritics but needs whole phrases', () => {
  assert.deepEqual(ids('NAHIHILO!!!'), ['dizziness']);
  assert.deepEqual(ids('Kinakapos ng hininga, sir'), ['shortness-of-breath']);
  assert.deepEqual(ids('Hindi humihinga ang pasyente'), ['not-breathing']);
  assert.deepEqual(ids('dizzyness unrelated'), []);
  assert.deepEqual(ids('lagnatan'), []);
  assert.deepEqual(ids('   '), []);
  assert.deepEqual(retrieve(index, 42), []);
  assert.equal(normalize('Pagkahilo, Café'), 'pagkahilo cafe');
});

test('Tagalog clitic particles inside a phrase do not break retrieval', () => {
  assert.ok(ids('nahihirapan siyang huminga').includes('shortness-of-breath'));
  assert.ok(ids('hirap po siya huminga').includes('shortness-of-breath'));
  assert.ok(ids('hindi po siya makalakad').includes('cannot-walk'));
  // A content word between phrase words still breaks the match.
  assert.ok(!ids('nahihirapan matinding huminga').includes('shortness-of-breath'));
  // A denial right before the phrase still flags it negated.
  const denied = retrieve(index, 'hindi nahihirapan siyang huminga').find((m) => m.id === 'shortness-of-breath');
  assert.equal(denied.negated, true);
});

test('the longest matching phrase is reported and results respect the limit', () => {
  const [match] = retrieve(index, 'malakas na pagdurugo sa braso');
  assert.equal(match.id, 'heavy-bleeding');
  assert.equal(match.matched, 'malakas na pagdurugo');
  const many = 'nahihilo nilalagnat nasusuka nagsusuka nanghihina sumasakit ang ulo sumasakit ang tiyan';
  assert.equal(retrieve(index, many, { limit: 3 }).length, 3);
  assert.equal(retrieve(index, many, { limit: 0 }).length, 0);
});

test('FTS query syntax in a transcript cannot break retrieval', () => {
  assert.doesNotThrow(() => retrieve(index, 'NEAR(" OR * AND ) "nahihilo" -x ^y'));
  assert.deepEqual(ids('" OR "" nahihilo'), ['dizziness']);
});

test('invalid packs are rejected, including any urgency or guideline fields', () => {
  const base = { packId: 'p', packVersion: '1', reviewStatus: 'unreviewed-draft',
    entries: [{ id: 'a', phrases: ['x'], filipino: 'x', english: 'x', medicalTerm: 'x', category: 'symptom' }] };
  assert.doesNotThrow(() => buildIndex(base));
  const withEntry = (patch) => ({ ...base, entries: [{ ...base.entries[0], ...patch }] });
  assert.throws(() => validatePack(withEntry({ triage: 'Immediate' })), /unsupported fields: triage/);
  assert.throws(() => validatePack(withEntry({ urgency: 'high' })), /unsupported fields/);
  assert.throws(() => validatePack(withEntry({ category: 'protocol' })), /category/);
  assert.throws(() => validatePack(withEntry({ phrases: [] })), /phrases/);
  assert.throws(() => validatePack({ ...base, reviewStatus: 'approved' }), /reviewStatus/);
  assert.throws(() => validatePack({ ...base, entries: [base.entries[0], base.entries[0]] }), /Duplicate/);
  assert.throws(() => validatePack(null), /entries/);
});

test('the glossary is reference text only: it is sent to Qwen but never confirms a finding', async () => {
  const matches = retrieve(index, 'Nahihilo ako at sumasakit ang dibdib ko.');
  assert.match(glossaryNote(matches), /nahihilo ako = Dizziness/);
  assert.match(glossaryNote(matches), /not patient evidence/);
  assert.equal(glossaryNote([]), '');

  let sent;
  const fetchImpl = async (_url, init) => {
    sent = JSON.parse(init.body);
    return { ok: true, status: 200, json: async () => ({ model: 'qwen3:0.6b', done: true, done_reason: 'stop',
      eval_count: 5, message: { content: '{}' } }) };
  };
  await callOllama('Nahihilo ako.', { fetchImpl, model: 'qwen3:0.6b', glossary: matches });
  assert.match(sent.messages[1].content, /Reference glossary/);

  // A model claim that is only "supported" by a glossary entry is still dropped.
  const out = toValidatedExtraction({ observations: { breathing: 'absent', consciousness: 'unknown',
    severeBleeding: 'unknown', walking: 'unknown' } }, 'Nahihilo ako at sumasakit ang dibdib ko.');
  assert.equal(out.observations.breathing, 'unknown');
});

test('POST /api/knowledge/lookup returns matches, never urgency, and rejects bad input', async () => {
  const app = createApp(openDb(':memory:'));
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const post = (body) => fetch(`${base}/api/knowledge/lookup`, { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const ok = await post({ transcript: 'Nahihilo ako at sumasakit ang dibdib ko.' });
    assert.equal(ok.status, 200);
    const data = await ok.json();
    assert.equal(data.retrieval.reviewStatus, 'unreviewed-draft');
    assert.equal(data.retrieval.matches.length, 2);
    assert.doesNotMatch(JSON.stringify(data), /triage|urgen/i);
    assert.equal((await post({ transcript: '' })).status, 400);
    assert.equal((await post({})).status, 400);
  } finally {
    server.close();
  }
});

test('shipped pack has 1000+ unique, well-formed entries and no clinical directives', () => {
  const entries = [...index.byId.values()];
  assert.ok(entries.length >= 1000, `expected 1000+ entries, got ${entries.length}`);
  assert.equal(new Set(entries.map((e) => e.id)).size, entries.length);
  const counts = new Map();
  for (const entry of entries) {
    for (const phrase of entry.phrases) {
      assert.ok(phrase.length >= 2, `phrase too short in ${entry.id}`);
      counts.set(phrase, (counts.get(phrase) || 0) + 1);
    }
    // The pack translates vocabulary. It must not smuggle in urgency, dosing or protocols.
    const text = [entry.english, entry.filipino, entry.medicalTerm].join(' ');
    assert.doesNotMatch(text, /\b(triage|immediate|urgent|delayed|minor|dose|dosage|\d+\s?mg|give|administer|protocol)\b/i, entry.id);
  }
  for (const [phrase, count] of counts) assert.ok(count <= 3, `phrase "${phrase}" is shared by ${count} entries`);
});

test('a phrase inside a longer matched phrase is not reported separately', () => {
  assert.deepEqual(ids('sumasakit ang dibdib'), ['chest-pain']);
  assert.deepEqual(ids('pumutok ang panubigan').filter((id) => id !== 'leaking-fluid-in-pregnancy'), []);
});

test('ordinary non-medical speech retrieves nothing', () => {
  for (const text of ['Si Juan ay nasa bahay po namin at kumakain ng kanin.', 'Please call me back tomorrow morning.', 'Salamat po, sige ingat kayo.']) {
    assert.deepEqual(ids(text), [], text);
  }
});

test('realistic Taglish field reports retrieve the expected terms', () => {
  assert.ok(ids('Buntis na babae, 38 weeks, pumutok ang panubigan, naglalabor na').includes('labor-pains'));
  assert.ok(ids('Nakagat ng aso kahapon, may lagnat').includes('dog-bite'));
  const crash = ids('Motorcycle crash, head injury, bleeding from head, unconscious, cannot move legs');
  for (const id of ['motorcycle-crash', 'head-injury', 'bleeding-from-head', 'unconscious', 'cannot-move-legs']) assert.ok(crash.includes(id), id);
});

test('self-audit: every phrase in the pack retrieves its own entry', () => {
  const missing = [];
  for (const entry of index.byId.values()) {
    for (const phrase of entry.phrases) {
      const found = retrieve(index, phrase, { limit: 20 }).map((m) => m.id);
      // Allowed only when a longer phrase of another entry contains this one.
      const covered = found.some((id) => index.byId.get(id).phrases.some((p) => p !== phrase && ` ${p} `.includes(` ${phrase} `)));
      if (!found.includes(entry.id) && !covered) missing.push(`${entry.id}: ${phrase}`);
    }
  }
  assert.deepEqual(missing, []);
});

test('entries that share a phrase are all returned, not one arbitrary winner', () => {
  const found = ids('may sipon po siya');
  assert.ok(found.includes('runny-nose'));
  assert.ok(ids('malakas na pagdurugo').length >= 2);
});

test('full-width and decomposed characters from phone keyboards still match', () => {
  assert.deepEqual(ids('\uff4e\uff41\uff48\uff49\uff48\uff49\uff4c\uff4f'), ['dizziness']);
  assert.deepEqual(ids('nahihilo'.normalize('NFD')), ['dizziness']);
  assert.equal(normalize('\uff21\uff22\uff23'), 'abc');
});

test('hostile input is handled quickly and without throwing', () => {
  const inputs = ['\u0000\u0000', 'a'.repeat(4000), 'nahihilo '.repeat(500), '\ud83d\ude00 nahihilo \u2764\ufe0f', 'NEAR/2 (a b) "unterminated', '\u0130stanbul \u01c5 \u00df'];
  const started = Date.now();
  for (const text of inputs) assert.doesNotThrow(() => retrieve(index, text));
  assert.deepEqual(ids('nahihilo '.repeat(500)), ['dizziness']);
  for (let i = 0; i < 200; i++) retrieve(index, 'Motorcycle crash head injury unconscious nahihilo '.repeat(80));
  assert.ok(Date.now() - started < 3000, 'retrieval over 200 long transcripts should stay well under 3s');
});

test('a denied term is flagged as negated; a stated or self-negating phrase is not', () => {
  const [denied] = retrieve(index, 'No severe bleeding, awake.').filter((m) => m.matched === 'severe bleeding');
  assert.equal(denied.negated, true);
  assert.equal(retrieve(index, 'hindi nahihilo').find((m) => m.id === 'dizziness').negated, true);
  assert.equal(retrieve(index, 'May severe bleeding sa braso.').find((m) => m.matched === 'severe bleeding').negated, false);
  // "walang malay" / "hindi humihinga" already contain their own negator: they are findings, not denials.
  assert.equal(retrieve(index, 'walang malay').find((m) => m.id === 'unconscious').negated, false);
  assert.equal(retrieve(index, 'hindi humihinga').find((m) => m.id === 'not-breathing').negated, false);
});

test('colloquial Tagalog and Taglish field phrasings retrieve the right terms', () => {
  const cases = {
    'nabagok ang ulo niya': 'head-injury',
    'nangingisay po siya': 'seizure',
    'hindi sumasagot ang pasyente': 'unresponsive',
    'bumubulwak ang dugo sa braso': 'pulsing-bleeding',
    'hindi makahinga ang bata': 'cannot-breathe',
    'nadaganan ng pader': 'crush-injury',
    'nagbigti po': 'hanging',
    'natuklaw ng ahas': 'snake-bite',
    'nakainom ng pestisidyo': 'swallowed-pesticide',
    'lumalabas na ang ulo ng bata': 'baby-crowning',
    'nasunog ang mukha': 'facial-burns',
    'binaril sa dibdib': 'gunshot-to-chest',
    'naiahon sa tubig': 'pulled-from-water',
    'tinangay ng baha': 'swept-away-by-flood',
    'hindi umiiyak ang baby': 'baby-not-crying',
    'nagwawala at nag-aamok': 'violent-outburst',
    'suspected stroke po': 'suspected-stroke',
    'possible dengue': 'suspected-dengue',
  };
  for (const [text, id] of Object.entries(cases)) assert.ok(ids(text).includes(id), `"${text}" should retrieve ${id}, got ${ids(text)}`);
});

test('the pack has grown to 1200+ entries without matching ordinary speech', () => {
  assert.ok(index.entryCount >= 1200, `got ${index.entryCount}`);
  for (const text of ['Please call me back tomorrow morning.', 'Salamat po, sige ingat kayo.', 'Si Juan ay nasa bahay po namin at kumakain ng kanin.',
    'Pumunta kami sa palengke kahapon at bumili ng isda.', 'Meeting at three, bring the report.']) assert.deepEqual(ids(text), [], text);
});

test('everyday Tagalog filler words and "yung" do not stop a phrase from matching', () => {
  for (const [text, id] of Object.entries({
    'Nahihirapan siyang huminga': 'shortness-of-breath',
    'masakit yung dibdib niya': 'chest-pain',
    'sumasakit po ang dibdib ko': 'chest-pain',
    'hindi na humihinga ang bata': 'not-breathing',
    'masakit yong ulo niya': 'headache',
  })) assert.ok(ids(text).includes(id), `"${text}" should retrieve ${id}, got ${ids(text)}`);
  // Fillers never turn unrelated speech into a finding.
  assert.deepEqual(ids('Si Juan ay nasa bahay po namin at kumakain ng kanin.'), []);
});

test('radial pulse vocabulary is offline guidance and cannot infer circulation from heart rate', () => {
  assert.ok(ids('May radial pulse ang pasyente.').includes('radial-pulse'));
  assert.ok(ids('Nakakapa ang pulso sa pulsohan.').includes('radial-pulse'));
  assert.equal(toValidatedExtraction({ circulation: 'present' }, 'Patient heart rate 80 bpm.').observations.circulation, 'unknown');
});
