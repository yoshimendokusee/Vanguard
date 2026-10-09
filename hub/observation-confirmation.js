const language = require('./observation-phrases.json');
const { OBSERVATIONS } = require('./risk');
const test = (pattern, text) => new RegExp(pattern, 'i').test(text);

// shortcut: bounded language grounding, expand only with reviewed phrases and shared regression cases.
function confirmObservations(claims, transcript) {
  const observations = {}, evidence = {}, warnings = [];
  const multiple = test(language.multiplePatients, transcript);
  const clauses = transcript.split(/(?<=\?)|[.!;,\n]+|(?=\b(?:correction|actually|now|ngayon|pala)\b)/i);
  for (const key of Object.keys(OBSERVATIONS)) {
    let hits = [];
    for (const clause of clauses) {
      if (multiple || test(language.otherSubject, clause) || test(language.instruction, clause)) continue;
      if (!test(language.mentions[key], clause) && !Object.values(language.phrases[key]).flat().some(p => clause.toLowerCase().includes(p))) continue;
      if (test(language.correction, clause)) hits = [];
      if (test(language.unassessed, clause) || (test(language.historical, clause) && !test(language.correction, clause))) {
        hits.push({ value: 'unknown', quote: null }); continue;
      }
      if (test(language.uncertainty, clause)) {
        hits.push({ value: ['circulation', 'severeBleeding'].includes(key) ? 'uncertain' : 'unknown', quote: clause.trim().slice(0, 120) }); continue;
      }
      let matches = [];
      for (const value of ['absent', 'abnormal', 'normal', 'unresponsive', 'alert', 'confused', 'present', 'uncertain', 'unable', 'able', 'assisted']) {
        const phrases = language.phrases[key][value] || [];
        for (const phrase of phrases) {
          const pattern = phrase.split(' ').map(word => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join(language.gap);
          for (const match of clause.matchAll(new RegExp(`\\b${pattern}\\b(?![-\\w])`, 'gi'))) {
            if (!test(language.negation, clause.slice(0, match.index))) matches.push({ value, quote: match[0], start: match.index, end: match.index + match[0].length });
          }
        }
      }
      // Longer denials/assisted statements contain shorter positive phrases.
      matches = matches.filter(hit => !matches.some(other => other.value !== hit.value && other.start <= hit.start && other.end >= hit.end));
      hits.push(...matches);
    }
    const values = new Set(hits.map(hit => hit.value));
    const hit = hits[0];
    observations[key] = values.size === 1 ? hit.value : 'unknown';
    evidence[key] = observations[key] === 'unknown' ? null : hit.quote.slice(0, 120);
    if (values.size > 1) warnings.push(`Contradictory statements about ${key}; treated as unknown`);
    else if (claims[key] && claims[key] !== observations[key]) warnings.push(`Unconfirmed claim for ${key}; transcript supports ${key}=${observations[key]}`);
  }
  return { observations, evidence, warnings };
}

module.exports = { confirmObservations };
