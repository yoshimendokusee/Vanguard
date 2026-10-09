/**
 * Deterministic report-field extraction for the hospital AI panel.
 *
 * Fills the fields a rescuer would otherwise type (location, patient count, age
 * group, ETA, injuries) from the transcript. Every value is paired with the exact
 * transcript text it came from; anything not stated stays null. This is plain
 * pattern matching plus the local terminology pack: no model output is trusted
 * for these fields and nothing here assigns urgency. The reviewer sees and can
 * edit every value before saving.
 */

const { retrieve, normalize, CLITIC_GAP, findPhraseSpan } = require('./rag/knowledge');

const NUMBER_WORDS = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  isa: 1, isang: 1, dalawa: 2, dalawang: 2, tatlo: 3, tatlong: 3, apat: 4, lima: 5, limang: 5,
  anim: 6, pito: 7, pitong: 7, walo: 8, walong: 8, siyam: 9, sampu: 10, sampung: 10,
};
const NUM = `(\\d{1,3}|${Object.keys(NUMBER_WORDS).join('|')})`;
const toNumber = (token) => (/^\d+$/.test(token) ? Number(token) : NUMBER_WORDS[token.toLowerCase()]);

const PATIENT_NOUNS = 'patients?|pasyente|victims?|biktima|casualt(?:y|ies)|persons?|people|tao|katao|injured|sugatan|bata|children|kids?|adults?|matanda|lalaki|babae|survivors?|riders?|passengers?';
const MINUTE_UNITS = 'minutes?|mins?|minuto';
const HOUR_UNITS = 'hours?|hrs?|oras';
const DURATION_UNITS = 'minutes?|mins?|minutos?|minuto|hours?|hrs?|oras?|days?|dias?|días?|weeks?|semanas?|months?|meses?';
const ETA_CUES = /\b(eta|arriv\w*|away|out|papunta|patungo|darating|dadating|dating|on the way|en route|to the hospital|sa ospital|bago makarating|makarating)\b/i;
const AGE_GROUPS = ['Infant', 'Child', 'Adult', 'Elderly'];

// Words that follow "in/sa/at" but are not a pickup location.
const NOT_PLACE = new Set(['a', 'an', 'the', 'my', 'his', 'her', 'their', 'our', 'ang', 'ng', 'mga', 'si', 'ni', 'kay', 'akin', 'kanya', 'critical', 'serious',
  'severe', 'pain', 'shock', 'labor', 'labour', 'distress', 'danger', 'trouble', 'condition', 'ospital', 'hospital', 'er', 'ed', 'emergency', 'ambulansya',
  'ambulance', 'sakit', 'hirap', 'dugo', 'blood', 'tubig', 'water', 'moment', 'minutes', 'minuto', 'oras', 'hours', 'araw', 'days', 'order', 'case', 'need',
  'progress', 'process', 'general', 'total', 'fact', 'addition', 'front', 'back', 'about', 'around', 'ibang', 'iba', 'pagitan', 'gitna', 'labas', 'loob', 'bubong', 'puno', 'hagdan', 'kama', 'sahig', 'traffic', 'roof', 'tree', 'stairs', 'bed', 'floor', 'ladder']);
const PLACE_STOP = new Set(['and', 'at', 'na', 'with', 'po', 'ang', 'ay', 'ng', 'mga', 'papunta', 'to', 'who', 'which', 'that', 'are', 'is', 'was', 'were',
  'after', 'because', 'but', 'pero', 'kasi', 'dahil', 'habang', 'ngayon', 'now', 'today', 'kanina', 'around', 'about', 'for', 'please', 'help', 'tulong',
  'nahulog', 'nabangga', 'sumasakit', 'masakit', 'may', 'walang', 'hindi', 'dalawa', 'dalawang', 'ten', 'eta', 'male', 'female', 'patient', 'pasyente']);

function wordsAfter(text, from) {
  const words = [];
  const re = /[\p{L}\p{N}][\p{L}\p{N}'’.-]*/gu;
  re.lastIndex = from;
  let m;
  while ((m = re.exec(text)) && words.length < 3) {
    // Stop at punctuation between words: "Arnaldo, 10 minutes" is one place, not two.
    if (words.length && /[,;:()!?]/.test(text.slice(words[words.length - 1].end, m.index))) break;
    if (PLACE_STOP.has(m[0].toLowerCase())) break;
    words.push({ text: m[0].replace(/[.'’-]+$/, ''), end: m.index + m[0].length });
  }
  return words;
}

function findLocation(transcript, index) {
  const patterns = [
    /\b(?:barangay|brgy\.?|bgy\.?)\s+(?=\p{L})/giu,
    /\b(?:purok|sitio|zone)\s+(?=[\p{L}\p{N}])/giu,
    /\b(?:malapit sa|dito sa|mula sa|galing sa|taga-?|near|from|in|at|sa)\s+(?=\p{L})/giu,
  ];
  for (const [position, re] of patterns.entries()) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(transcript))) {
      const words = wordsAfter(transcript, m.index + m[0].length);
      if (!words.length) continue;
      if (position === 2 && NOT_PLACE.has(words[0].text.toLowerCase())) continue;
      // Tagalog "at" means "and": treat it as a place marker only before a capitalized name.
      if (position === 2 && /^at\s/i.test(m[0]) && !/^\p{Lu}/u.test(words[0].text)) continue;
      const value = words.map((w) => w.text).join(' ');
      // A body part, symptom or injury is not a place ("sumasakit sa dibdib").
      if (position === 2 && retrieve(index, value).some((t) => t.matched === normalize(value))) continue;
      const label = position < 2 ? `${/^(?:brgy|bgy)/i.test(m[0]) || /^barangay/i.test(m[0]) ? 'Barangay' : m[0].trim()[0].toUpperCase() + m[0].trim().slice(1)} ${value}` : value;
      // Title-case only an all-lowercase place so the form reads naturally; the evidence stays verbatim.
      const shown = label === label.toLowerCase() ? label.replace(/\b\p{L}/gu, (c) => c.toUpperCase()) : label;
      return { value: shown, basis: position < 2 ? 'explicit' : 'inferred', evidence: transcript.slice(m.index, words[words.length - 1].end) };
    }
  }
  return null;
}

function findPatientCount(transcript) {
  // Clitic particles may sit between the number and the noun: "dalawa na bata",
  // "tatlong po siyang tao". The gap only absorbs particles, never content words.
  const m = new RegExp(`\\b${NUM}${CLITIC_GAP}(?:${PATIENT_NOUNS})\\b`, 'iu').exec(transcript);
  if (!m) return null;
  const value = toNumber(m[1]);
  return Number.isInteger(value) && value >= 1 && value <= 99 ? { value, evidence: m[0] } : null;
}

function bandForYears(years) {
  if (years < 1) return 'Infant';
  if (years <= 12) return 'Child';
  if (years >= 60) return 'Elderly';
  if (years >= 18) return 'Adult';
  return null; // 13-17 is ambiguous: leave it for the reviewer
}

function findAgeGroup(transcript) {
  const found = new Map();
  const add = (group, evidence) => { if (group && !found.has(group)) found.set(group, evidence); };
  for (const m of transcript.matchAll(/\b(\d{1,3})[\s-]*(?:years?|yrs?|yr|taong|taon|anyos|y\/?o)(?:[\s-]*old|\s+gulang)?\b/giu)) add(bandForYears(Number(m[1])), m[0]);
  for (const m of transcript.matchAll(/\b(\d{1,2})[\s-]*(?:months?|buwan)(?:[\s-]*old)?\b/giu)) add(Number(m[1]) < 12 ? 'Infant' : 'Child', m[0]);
  const words = [
    ['Infant', /\b(infants?|babies|baby|newborns?|sanggol|bagong silang)\b/iu],
    ['Child', /\b(child|children|kids?|toddlers?|bata|mga bata|paslit)\b/iu],
    ['Elderly', /\b(elderly|seniors?|senior citizens?|lolo|lola|nakatatanda|matanda na|old (?:man|woman))\b/iu],
    ['Adult', /\b(adults?|nasa hustong gulang)\b/iu],
  ];
  for (const [group, re] of words) { const m = re.exec(transcript); if (m) add(group, m[0]); }
  if (found.size !== 1) return found.size ? { value: 'Unspecified', evidence: [...found.values()].join(' / '), mixed: true } : null;
  const [[value, evidence]] = found.entries();
  return AGE_GROUPS.includes(value) ? { value, evidence } : null;
}

function findEta(transcript) {
  const re = new RegExp(`\\b${NUM}\\s*(?:(${MINUTE_UNITS})|(${HOUR_UNITS}))\\b`, 'giu');
  for (const m of transcript.matchAll(re)) {
    // Only a minutes figure next to an arrival cue is an ETA: "unconscious for 10 minutes" is not.
    const around = transcript.slice(Math.max(0, m.index - 60), m.index + m[0].length + 60);
    if (!ETA_CUES.test(around)) continue;
    // "30 minutes ago" / "mga 30 minutes na" says how long it has been, not when they arrive ("limang minuto na lang" stays an ETA).
    if (/^\s*(?:ago\b|already\b|na\b(?!\s+lang))/i.test(transcript.slice(m.index + m[0].length, m.index + m[0].length + 14))) continue;
    const minutes = toNumber(m[1]) * (m[3] ? 60 : 1);
    if (Number.isInteger(minutes) && minutes >= 1 && minutes <= 720) return { value: minutes, evidence: m[0] };
  }
  return null;
}

function findSymptomDuration(transcript) {
  const re = new RegExp(`\\b${NUM}\\s*(${DURATION_UNITS})\\b`, 'giu');
  for (const match of transcript.matchAll(re)) {
    const start = match.index;
    const end = start + match[0].length;
    const before = transcript.slice(Math.max(0, start - 28), start);
    const after = transcript.slice(end, end + 16);
    const beforeCue = /\b(?:for|since|past|mula|simula)\b[^.!?;:,]{0,24}$/i.exec(before);
    const afterCue = /^\s*(?:na|nang|ago)\b/i.exec(after);
    if (!beforeCue && !afterCue) continue;
    if (ETA_CUES.test(before + after) && !beforeCue && !/\bago\b/i.test(afterCue[0])) continue;
    const value = toNumber(match[1]);
    if (!Number.isInteger(value) || value < 1) continue;
    const unitText = match[2].toLowerCase();
    const unit = /^(?:minutes?|mins?|minutos?|minuto)/.test(unitText) ? 'minutes'
      : /^(?:hours?|hrs?|oras?)/.test(unitText) ? 'hours'
        : /^(?:days?|d[ií]as?)/.test(unitText) ? 'days'
          : /^(?:weeks?|semanas?)/.test(unitText) ? 'weeks' : 'months';
    const excerpt = beforeCue
      ? transcript.slice(start - before.length + beforeCue.index, end)
      : transcript.slice(start, end + afterCue[0].length).trim();
    return { value, unit, evidence: excerpt };
  }
  return null;
}

const FINDING_CATEGORIES = new Set(['injury', 'condition', 'mechanism', 'symptom']);

/**
 * `observationInjuries` are the legacy-vocabulary labels already derived from the
 * four validated findings. Terms from the pack are appended; denied ones are skipped.
 */
function injuriesFor(transcript, index, observationInjuries) {
  const terms = [];
  const seen = new Set();
  const covered = new Set();
  const push = (label) => {
    const key = label.toLowerCase();
    if (!seen.has(key)) { seen.add(key); terms.push(label); }
  };
  observationInjuries.forEach((label) => {
    push(label);
    covered.add(label.toLowerCase());
    if (label === 'Difficulty breathing') covered.add('shortness of breath');
    if (label === 'Ambulatory') covered.add('can walk');
  });
  for (const match of index ? retrieve(index, transcript, { limit: 12 }) : []) {
    if (!match.negated && FINDING_CATEGORIES.has(match.category) && !covered.has(match.english.toLowerCase())) push(match.english);
  }
  let joined = '';
  const used = [];
  for (const label of terms) {
    const next = joined ? `${joined}, ${label}` : label;
    if (next.length > 300) break;
    joined = next;
    used.push(label);
  }
  return { value: joined || 'Unspecified', terms: used };
}

function terminologyFindings(transcript, index) {
  return (index ? retrieve(index, transcript, { limit: 12 }) : []).flatMap((match, position) => {
    if (match.negated || !FINDING_CATEGORIES.has(match.category)) return [];
    const hit = findPhraseSpan(transcript, match.matched);
    if (!hit) return [];
    return [{ id: `reported-term-${position + 1}`, kind: match.category === 'mechanism' || match.category === 'injury' ? 'incident' : 'symptom',
      name: match.english.slice(0, 100), value: 'reported', unit: null, source: 'model-inferred', excerpt: hit.quote, contradictory: false }];
  });
}

function extractReportFields(transcript, index, observationInjuries = []) {
  const location = findLocation(transcript, index);
  const patientCount = findPatientCount(transcript);
  const ageGroup = findAgeGroup(transcript);
  const eta = findEta(transcript);
  const symptomDuration = findSymptomDuration(transcript);
  const injuries = injuriesFor(transcript, index, observationInjuries);
  return {
    fields: {
      location: location ? location.value : null,
      patientCount: patientCount ? patientCount.value : null,
      ageGroup: ageGroup ? ageGroup.value : 'Unspecified',
      etaMinutes: eta ? eta.value : null,
      symptomDuration: symptomDuration ? { value: symptomDuration.value, unit: symptomDuration.unit } : null,
      injuries: injuries.value,
    },
    evidence: {
      location: location ? location.evidence : null,
      patientCount: patientCount ? patientCount.evidence : null,
      ageGroup: ageGroup ? ageGroup.evidence : null,
      etaMinutes: eta ? eta.evidence : null,
      symptomDuration: symptomDuration ? symptomDuration.evidence : null,
    },
    locationBasis: location ? location.basis : null,
    notes: ageGroup && ageGroup.mixed ? ['Different age groups were mentioned; age group left unspecified'] : [],
    findings: terminologyFindings(transcript, index),
  };
}

module.exports = { extractReportFields, findLocation, findPatientCount, findAgeGroup, findEta, findSymptomDuration, injuriesFor };
