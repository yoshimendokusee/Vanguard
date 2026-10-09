const { validateObservations } = require('./risk');

function text(value, max, allowEmpty = false) {
  return typeof value === 'string' && value.length <= max && (allowEmpty || value.trim().length > 0);
}

// Normalize key order so equivalent JSON replays have the same durable identity.
function validateProcessing(value) {
  if (!value || Array.isArray(value) || value.version !== 1 || !text(value.originalTranscript, 16000, true)
    || !validateObservations(value.observations)
    || !Array.isArray(value.uncertainties) || value.uncertainties.length > 30
    || !value.uncertainties.every((item) => text(item, 300))) return { error: 'invalid processing' };
  const provenance = value.provenance;
  if (!provenance || !['apple-watch', 'iphone', 'wear-os', 'hospital-browser'].includes(provenance.device)
    || !text(provenance.sttEngine, 100) || !text(provenance.sttRuntime, 100)) return { error: 'invalid provenance' };
  let extraction = null;
  if (provenance.extraction != null) {
    const p = provenance.extraction;
    if (!text(p.model, 100) || !text(p.revision, 100) || !text(p.runtime, 100)
      || !/^[a-f0-9]{64}$/.test(p.artifactSha256) || p.execution !== 'local') return { error: 'invalid extraction provenance' };
    extraction = { model: p.model, revision: p.revision, runtime: p.runtime,
      artifactSha256: p.artifactSha256, execution: p.execution };
  }
  const evidence = value.evidence === undefined ? {} : value.evidence;
  if (!evidence || typeof evidence !== 'object' || Array.isArray(evidence)
    || Object.keys(evidence).some((key) => !Object.hasOwn(value.observations, key))) return { error: 'invalid evidence' };
  const sources = ['reported', 'observed', 'model-inferred'];
  const normalizedEvidence = {};
  for (const [key, item] of Object.entries(evidence)) {
    if (!item || !sources.includes(item.source) || !text(item.excerpt, 1000)
      || !value.originalTranscript.includes(item.excerpt) || typeof item.contradictory !== 'boolean') {
      return { error: 'invalid observation source reference' };
    }
    normalizedEvidence[key] = { source: item.source, excerpt: item.excerpt, contradictory: item.contradictory };
  }
  const findings = value.findings === undefined ? [] : value.findings;
  if (!Array.isArray(findings) || findings.length > 100) return { error: 'invalid findings' };
  const normalizedFindings = [];
  for (const item of findings) {
    if (!item || !text(item.id, 64) || !['symptom', 'observation', 'vital', 'patient', 'incident'].includes(item.kind)
      || !text(item.name, 100) || !(item.value === null || text(item.value, 500) || (typeof item.value === 'number' && Number.isFinite(item.value)))
      || !(item.unit == null || text(item.unit, 50)) || ![...sources, 'unavailable'].includes(item.source)
      || typeof item.contradictory !== 'boolean'
      || (item.source === 'unavailable' ? item.value !== null || item.excerpt != null
        : !text(item.excerpt, 1000) || !value.originalTranscript.includes(item.excerpt))) return { error: 'invalid finding source reference' };
    normalizedFindings.push({ id: item.id, kind: item.kind, name: item.name, value: item.value,
      unit: item.unit ?? null, source: item.source, excerpt: item.excerpt ?? null, contradictory: item.contradictory });
  }
  if (new Set(normalizedFindings.map((item) => item.id)).size !== findings.length) return { error: 'duplicate finding ID' };
  return { value: {
    version: 1,
    originalTranscript: value.originalTranscript,
    observations: Object.fromEntries(['breathing', 'consciousness', 'severeBleeding', 'walking', ...(Object.hasOwn(value.observations, 'circulation') ? ['circulation'] : [])].map((key) => [key, value.observations[key]])),
    uncertainties: value.uncertainties,
    provenance: { device: provenance.device, sttEngine: provenance.sttEngine, sttRuntime: provenance.sttRuntime, extraction },
    evidence: normalizedEvidence,
    findings: normalizedFindings,
  } };
}

module.exports = { validateProcessing, text };
