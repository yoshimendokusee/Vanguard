const { validateObservations } = require('./risk');

function text(value, max, allowEmpty = false) {
  return typeof value === 'string' && value.length <= max && (allowEmpty || value.trim().length > 0);
}

// Normalize key order so equivalent JSON replays have the same durable identity.
function validateProcessing(value) {
  if (!value || value.version !== 1 || !text(value.originalTranscript, 16000, true)
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
  return { value: {
    version: 1,
    originalTranscript: value.originalTranscript,
    observations: Object.fromEntries(['breathing', 'consciousness', 'severeBleeding', 'walking'].map((key) => [key, value.observations[key]])),
    uncertainties: value.uncertainties,
    provenance: { device: provenance.device, sttEngine: provenance.sttEngine, sttRuntime: provenance.sttRuntime, extraction },
  } };
}

module.exports = { validateProcessing, text };
