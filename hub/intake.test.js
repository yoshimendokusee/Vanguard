const test = require('node:test');
const assert = require('node:assert/strict');
const { loadKnowledge } = require('./rag/knowledge');
const { extractReportFields, findLocation, findAgeGroup, findEta, findPatientCount } = require('./intake');
const { validateReport } = require('./sync');
const { riskForRow } = require('./risk');

const index = loadKnowledge();
const extract = (text, labels = []) => extractReportFields(text, index, labels);

test('fills the fields from a bare English report', () => {
  const { fields, evidence } = extract('concussion with internal bleeding in arnaldo');
  assert.equal(fields.location, 'Arnaldo');
  assert.equal(fields.injuries, 'Internal bleeding, Concussion');
  assert.equal(fields.patientCount, null);
  assert.equal(fields.etaMinutes, null);
  assert.equal(fields.ageGroup, 'Unspecified');
  assert.equal(evidence.location, 'in arnaldo');
});

test('fills every field from a Taglish rescuer report', () => {
  const { fields, evidence } = extract('Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, sampung minuto papunta sa ospital.');
  assert.deepEqual(fields, { location: 'Barangay Arnaldo', patientCount: 2, ageGroup: 'Child', etaMinutes: 10, injuries: 'Drowning' });
  assert.equal(evidence.etaMinutes, 'sampung minuto');
  assert.equal(extract('Motorcycle crash, male, in Brgy. San Roque, ETA 15 minutes').fields.location, 'Barangay San Roque');
  assert.equal(extract('taga-Sitio Mabini, buntis, 20 minutes away').fields.location, 'Sitio Mabini');
  assert.equal(extract('Baby, lagnat, sa Purok 5 Bagumbayan').fields.location, 'Purok 5 Bagumbayan');
});

test('an unrelated sentence fills nothing', () => {
  const { fields } = extract('Si Juan ay nasa bahay po namin at kumakain ng kanin.');
  assert.deepEqual(fields, { location: null, patientCount: null, ageGroup: 'Unspecified', etaMinutes: null, injuries: 'Unspecified' });
});

test('minutes count as an ETA only next to an arrival cue', () => {
  assert.equal(findEta('Unconscious for 10 minutes, bleeding'), null);
  assert.equal(findEta('ETA 15 minutes').value, 15);
  assert.equal(findEta('arriving in 1 hour').value, 60);
  assert.equal(findEta('12 mins out').value, 12);
  assert.equal(findEta('limang minuto na lang darating').value, 5);
  assert.equal(findEta('arriving in 900 minutes'), null, 'outside the 1-720 minute limit the hub accepts');
});

test('age group comes from stated words or ages, and stays unspecified when ambiguous or mixed', () => {
  assert.equal(findAgeGroup('male 30 years old').value, 'Adult');
  assert.equal(findAgeGroup('Lolo na 72 anyos').value, 'Elderly');
  assert.equal(findAgeGroup('8 years old').value, 'Child');
  assert.equal(findAgeGroup('baby 3 months old').value, 'Infant');
  assert.equal(findAgeGroup('15 years old'), null, '13-17 is left for the reviewer');
  assert.equal(findAgeGroup('adult and child').value, 'Unspecified');
  assert.deepEqual(extract('adult and child, two patients').notes, ['Different age groups were mentioned; age group left unspecified']);
  assert.equal(findAgeGroup('Nahihilo ako'), null);
});

test('patient count needs a number next to a patient noun and never reads ages or durations', () => {
  assert.equal(findPatientCount('three patients').value, 3);
  assert.equal(findPatientCount('Dalawang bata').value, 2);
  assert.equal(findPatientCount('isang pasyente').value, 1);
  assert.equal(findPatientCount('5 injured').value, 5);
  assert.equal(findPatientCount('30 years old, 10 minutes away'), null);
  assert.equal(findPatientCount('0 patients'), null);
});

test('places that are not pickup locations are not guessed', () => {
  for (const text of ['Patient is in critical condition in the hospital', 'Nahulog sa bubong', 'sumasakit sa dibdib', 'in a motorcycle crash',
    'sa ospital', 'in labor', 'in pain', 'masakit sa braso']) {
    assert.equal(findLocation(text, index), null, text);
  }
  assert.equal(findLocation('namin at kumakain ng kanin', index), null, 'Tagalog "at" means "and"');
  assert.equal(findLocation('Barangay Arnaldo', index).basis, 'explicit');
  assert.equal(findLocation('near Plaza Rizal', index).basis, 'inferred');
  assert.equal(findLocation('at Riverside Road, 10 minutes out', index).value, 'Riverside Road');
});

test('injury terms come from the pack, skip denied ones and keep the validated findings first', () => {
  assert.equal(extract('Walang chest pain, may sugat sa braso').fields.injuries.includes('Chest pain'), false);
  const labels = extract('Head injury, nahihilo ako, namamaga ang binti', ['Unconscious']).fields.injuries.split(', ');
  assert.equal(labels[0], 'Unconscious');
  assert.ok(labels.includes('Head injury') && labels.includes('Dizziness'));
  // Anatomy, history and observation-only signs are not injuries.
  const plain = extract('Buntis na babae, may sipon, sa Barangay Uno').fields.injuries;
  assert.doesNotMatch(plain, /Pregnant|Female|Barangay/);
  assert.equal(extract('nahihilo nahihilo nahihilo').fields.injuries, 'Dizziness');
  // Always fits the hub's 300 character limit.
  const crowded = extract('nahihilo nilalagnat nasusuka nagsusuka nanghihina sumasakit ang ulo sumasakit ang tiyan', Array(40).fill('Severe bleeding').map((s, i) => `${s} ${i}`)).fields.injuries;
  assert.ok(crowded.length <= 300);
});

test('every filled value is quoted verbatim from the transcript', () => {
  const samples = [
    'concussion with internal bleeding in arnaldo',
    'Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, sampung minuto papunta sa ospital.',
    'Motorcycle crash, male 30 years old, head injury, in Brgy. San Roque, ETA 15 minutes',
    'Lolo na 72 anyos, nahilo, near Plaza Rizal, one patient',
    'Baby 3 months old, lagnat, sa Purok 5 Bagumbayan, 12 mins out',
    'three patients, adult and child, at Riverside Road, arriving in 1 hour',
  ];
  for (const text of samples) {
    const { evidence } = extract(text);
    for (const [field, quote] of Object.entries(evidence)) {
      if (quote === null) continue;
      assert.ok(quote.split(' / ').every((part) => text.toLowerCase().includes(part.toLowerCase())), `${field} evidence "${quote}" not in "${text}"`);
    }
  }
});

test('filled fields always pass the hub report validator and never lower urgency', () => {
  const samples = ['concussion with internal bleeding in arnaldo', 'Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, sampung minuto papunta sa ospital.',
    'x'.repeat(10), 'nahihilo '.repeat(100), 'Si Juan ay nasa bahay po namin.', 'adult and child at Riverside Road, 99 patients, 720 minutes away'];
  for (const text of samples) {
    const { fields } = extract(text);
    const checked = validateReport({ createdAt: '2026-10-10T00:00:00.000Z', triage: 'Unassessed', location: fields.location || 'Unknown',
      injuries: fields.injuries, patientCount: fields.patientCount, ageGroup: fields.ageGroup, etaMinutes: fields.etaMinutes });
    assert.equal(checked.error, undefined, `${text.slice(0, 40)}: ${checked.error}`);
    // Saved as Unassessed: the legacy rules may raise urgency but can never lower it.
    const risk = riskForRow({ injuries: fields.injuries, triage: 'Unassessed' });
    assert.ok(['Immediate', 'Unassessed'].includes(risk.effective_triage));
  }
  // The hospital's own legacy words still apply when the reviewer saves them.
  assert.equal(riskForRow({ injuries: extract('sumasakit ang dibdib').fields.injuries, triage: 'Unassessed' }).effective_triage, 'Immediate');
});
