const OBSERVATIONS = {
  breathing: ['normal', 'abnormal', 'absent', 'unknown'],
  consciousness: ['alert', 'unresponsive', 'unknown'],
  severeBleeding: ['present', 'absent', 'unknown'],
  walking: ['able', 'unable', 'unknown'],
};
const RULE_VERSION = 'provisional-v1';

function validateObservations(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every((key) => Object.hasOwn(OBSERVATIONS, key))
    && Object.entries(OBSERVATIONS).every(([key, options]) => options.includes(value[key]));
}

// Prototype rules only: unknown never means normal; no automatic death declaration.
function assessRisk(observations) {
  const reasons = [];
  if (['abnormal', 'absent'].includes(observations.breathing)) reasons.push(`Breathing: ${observations.breathing}`);
  if (observations.consciousness === 'unresponsive') reasons.push('Unresponsive');
  if (observations.severeBleeding === 'present') reasons.push('Severe bleeding reported');
  let triage = 'Unassessed';
  if (reasons.length) triage = 'Immediate';
  else if (observations.walking === 'unable') {
    triage = 'Delayed';
    reasons.push('Unable to walk; other critical findings not established');
  } else if (observations.walking === 'able' && observations.breathing === 'normal'
    && observations.consciousness === 'alert' && observations.severeBleeding === 'absent') {
    triage = 'Minor';
    reasons.push('Walking, alert, normal breathing, no severe bleeding reported');
  } else reasons.push('Insufficient explicit observations; qualified assessment required');
  return { triage, reason: reasons.join('; '), version: RULE_VERSION };
}

const LEGACY_RULES = {
  Immediate: ['Not breathing', 'Difficulty breathing', 'Drowning', 'Unconscious', 'Severe bleeding',
    'Head injury', 'Chest pain', 'Electrocution', 'Pregnant / labor'],
  Delayed: ['Fracture', 'Laceration', 'Bleeding', 'Wound', 'Hypothermia', 'Burn', 'Snakebite',
    'Weak / dehydrated', 'Non-ambulatory'],
  Minor: ['Abrasion', 'Ambulatory'],
};

function riskForRow(row) {
  const findings = row.injuries.split(',').map((finding) => finding.trim());
  let triage = 'Unassessed';
  let reason = 'No recognized structured finding; qualified assessment required';
  for (const [category, triggers] of Object.entries(LEGACY_RULES)) {
    const matched = findings.filter((finding) => triggers.includes(finding));
    if (!matched.length) continue;
    triage = category;
    reason = `${category} triggered by: ${matched.join(', ')}`;
    break;
  }
  // Keep a rescuer's higher urgency; unknown is never downgraded to Minor/Delayed.
  const rank = { Immediate: 0, Unassessed: 1, Delayed: 2, Minor: 3, Deceased: 4 };
  const effective = rank[row.triage] < rank[triage] ? row.triage : triage;
  return { provisional_triage: triage, effective_triage: effective, risk_reason: reason,
    rule_version: 'legacy-findings-v1', requires_verification: true };
}

module.exports = { validateObservations, assessRisk, RULE_VERSION, LEGACY_RULES, riskForRow };
