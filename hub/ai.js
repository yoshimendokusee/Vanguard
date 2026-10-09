/**
 * Vanguard-Wrist local AI module (Qwen via Ollama).
 *
 * Runs inside the existing Express hub — no new server, container or framework.
 * Qwen is an information-extraction assistant only: it returns structured
 * observations with evidence and uncertainty. The deterministic engine in
 * `risk.js` (`assessRisk`) stays authoritative for provisional triage, and the
 * existing SQLite + `/api/sync-triage` path stays authoritative for storage.
 *
 * Design notes:
 * - One Ollama call per request, bounded by AbortController timeout. No retries,
 *   so an unavailable Ollama fails fast instead of hammering the host.
 * - `think: false` (Qwen3) keeps the 0.6B model fast and its output JSON-only.
 * - Model output is validated against the real schema before anything is
 *   returned. Unsupported enum values are downgraded to `unknown` (safe
 *   direction) with a visible warning — never invented, never treated as absent.
 * - Evidence excerpts are grounded: a non-unknown observation without a
 *   transcript substring is downgraded to `unknown`.
 * - Raw transcripts are never logged; only lengths and error codes are logged.
 */

const { assessRisk, validateObservations, riskForRow } = require('./risk');
const { extractReportFields } = require('./intake');
const { verifyModel } = require('./model');
const { isIP } = require('node:net');
const { loadKnowledge, retrieve, packInfo, findPhraseSpan } = require('./rag/knowledge');
const fs = require('node:fs');
const path = require('node:path');

const PROMPT_VERSION = 'vanguard-extract-v2';

// Offline terminology retrieval is optional context: a missing or invalid pack
// must never block extraction, so failures fall back to no glossary.
let knowledge;
function knowledgeIndex() {
  if (process.env.RAG_ENABLED === '0') return null;
  if (knowledge === undefined) {
    try { knowledge = loadKnowledge(); }
    catch (error) { knowledge = null; console.log(`[rag] disabled: ${error.message}`); }
  }
  return knowledge;
}

function glossaryFor(transcript) {
  const index = knowledgeIndex();
  const found = index ? retrieve(index, transcript) : [];
  // The prompt gets one meaning per phrase and never a denied one ("no severe
  // bleeding"); the response keeps every match, flagged, for the reviewer.
  const seen = new Set();
  const matches = found.filter((m) => {
    if (m.negated || seen.has(m.matched)) return false;
    seen.add(m.matched);
    return true;
  });
  return {
    matches,
    retrieval: index ? { ...packInfo(index), matches: found } : null,
  };
}

function aiConfig() {
  const ollamaUrl = (process.env.OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/+$/, '');
  let url;
  try { url = new URL(ollamaUrl); } catch { throw new AiError('invalid-runtime-url', 'OLLAMA_URL must be an absolute local HTTP URL', 503); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new AiError('invalid-runtime-url', 'OLLAMA_URL must contain only scheme, host and port', 503);
  }
  const positive = (name, fallback, max) => {
    const value = Number(process.env[name] || fallback);
    if (!Number.isSafeInteger(value) || value < 1 || value > max) throw new AiError('invalid-ai-config', `Invalid ${name}`, 503);
    return value;
  };
  return {
    ollamaUrl,
    model: process.env.OLLAMA_MODEL || 'qwen3:0.6b',
    timeoutMs: positive('AI_TIMEOUT_MS', 120000, 300000),
    statusTimeoutMs: positive('AI_STATUS_TIMEOUT_MS', 4000, 30000),
    maxTranscript: positive('AI_MAX_TRANSCRIPT', 4000, 4000),
    numThreads: positive('AI_NUM_THREADS', 2, 32),
    promptVersion: PROMPT_VERSION,
  };
}

class AiError extends Error {
  constructor(code, message, httpStatus = 502) {
    super(message);
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

const ALLOWED = {
  breathing: ['normal', 'abnormal', 'absent', 'unknown'],
  consciousness: ['alert', 'unresponsive', 'unknown'],
  severeBleeding: ['present', 'absent', 'unknown'],
  walking: ['able', 'unable', 'unknown'],
};

const SYSTEM_PROMPT = [
  'Classify the rescuer report into 4 fields. Reply ONLY JSON like {"breathing":"abnormal","consciousness":"unresponsive","severeBleeding":"present","walking":"unable"}.',
  'Allowed values: breathing normal|abnormal|absent|unknown; consciousness alert|unresponsive|unknown; severeBleeding present|absent|unknown; walking able|unable|unknown.',
  'Decide only from the report; unsure means unknown. Example critical: "nalunod, walang malay, malakas na pagdurugo, hindi makalakad" gives breathing abnormal, consciousness unresponsive, severeBleeding present, walking unable. Example healthy: "awake, breathing normally, no bleeding, can walk" gives breathing normal, consciousness alert, severeBleeding absent, walking able. Hints: "not breathing"/"hindi humihinga"=absent breathing; "difficulty breathing"/"nahihirapan"/"nalunod"/"drowning"=abnormal; "breathing normally"=normal; "unconscious"/"walang malay"/"unresponsive"=unresponsive; "awake"/"gising"/"alert"=alert; "malakas na pagdurugo"/"severe bleeding"/"heavy bleeding"=present; "no bleeding"/"walang dugo"=absent; "cannot walk"/"hindi makalakad"=unable; "can walk"/"nakakalakad"=able.',
].join('\n');

function validateTranscriptInput(body, maxTranscript) {
  const t = body && body.transcript;
  if (typeof t !== 'string' || !t.trim()) {
    return { error: { code: 'invalid-transcript', message: 'transcript must be a non-empty string' } };
  }
  if (t.length > maxTranscript) {
    return { error: { code: 'transcript-too-long', message: `transcript exceeds ${maxTranscript} characters` } };
  }
  return { transcript: t };
}

function cleanDevice(value) {
  const allowed = ['hospital-browser', 'iphone', 'apple-watch', 'wear-os'];
  return allowed.includes(value) ? value : 'hospital-browser';
}

function textOr(value, fallback, max = 100) {
  return typeof value === 'string' && value.trim() && value.length <= max ? value : fallback;
}

/** Strip Qwen <think> blocks, code fences and surrounding chatter; parse the JSON object. */
function extractJsonObject(text) {
  if (typeof text !== 'string' || !text.trim()) throw new AiError('empty-model-response', 'Model returned an empty response', 502);
  let s = text.replace(/<think>[\s\S]*?<\/think>/gi, ' ').replace(/```(?:json)?/gi, ' ').replace(/```/g, ' ');
  const start = s.indexOf('{');
  const end = s.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) {
    throw new AiError('invalid-model-json', 'Model did not return JSON', 502);
  }
  try {
    const parsed = JSON.parse(s.slice(start, end + 1));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('not an object');
    }
    return parsed;
  } catch {
    throw new AiError('invalid-model-json', 'Model returned malformed JSON', 502);
  }
}

function coerceEnum(key, value, warnings) {
  if (typeof value === 'string') {
    const v = value.trim().toLowerCase();
    if (ALLOWED[key].includes(v)) return v;
  }
  if (value !== undefined && value !== null && String(value).trim().toLowerCase() !== 'unknown') {
    warnings.push(`Model value for ${key} was unsupported and treated as unknown`);
  }
  return 'unknown';
}

function strArray(value, maxItems, maxLen) {
  if (!Array.isArray(value)) return [];
  return value.filter((s) => typeof s === 'string' && s.trim()).map((s) => s.trim().slice(0, maxLen)).slice(0, maxItems);
}

// Server-side confirmation vocabulary. Mirrors the watch parser's Tagalog/English
// keywords: a model claim counts only when one of these phrases actually occurs
// in the transcript. Tagalog clitics/linkers between a phrase's words are
// tolerated ("nahihirapan siyang huminga" confirms "nahihirapan huminga"), but
// word boundaries still hold ("conscious" never matches "unconscious", "can
// walk" never matches "cannot walk") and no particle is a negator. This keeps
// the tiny model honest: unconfirmed claims become unknown instead of findings.
const CONFIRM = {
  breathing: {
    absent: ['not breathing', 'hindi humihinga', 'di humihinga', 'no breathing', 'stopped breathing', 'walang paghinga', 'walang hininga', 'wala nang hininga'],
    abnormal: ['difficulty breathing', 'nahihirapan huminga', 'mahirap huminga', 'hirap huminga', 'hirap sa paghinga', 'hinihingal', 'kinakapos ng hininga', 'kapos hininga', 'hindi makahinga', 'di makahinga', 'cannot breathe', "can't breathe", 'cant breathe', 'can t breathe', 'unable to breathe', 'drowning', 'nalunod', 'shortness of breath', 'trouble breathing', 'gasping', 'difficulty of breathing'],
    normal: ['breathing normally', 'normal breathing', 'breathing fine', 'breathing ok', 'humihinga nang normal', 'normal huminga', 'nakakahinga', 'makahinga', 'humihinga'],
  },
  consciousness: {
    unresponsive: ['unconscious', 'walang malay', 'unresponsive', 'not responding', 'no response', 'passed out', 'nawalan ng malay', 'unconsciousness', 'walang ulirat', 'nawalan ng ulirat', 'hindi sumasagot', 'di sumasagot'],
    alert: ['awake', 'gising', 'alert', 'conscious', 'responsive', 'mulat'],
  },
  severeBleeding: {
    present: ['severe bleeding', 'malakas na pagdurugo', 'heavy bleeding', 'lots of blood', 'maraming dugo', 'severe blood loss', 'bleeding heavily', 'bleeding a lot', 'profuse bleeding', 'sobrang dugo', 'duguan', 'massive bleeding', 'hemorrhage'],
    absent: ['no severe bleeding', 'no bleeding', 'walang dugo', 'walang pagdurugo', 'no blood', 'bleeding stopped', 'hindi dumudugo', 'di dumudugo'],
  },
  walking: {
    unable: ['cannot walk', "can't walk", 'hindi makalakad', 'di makalakad', 'hindi nakakalakad', 'di nakakalakad', 'cannot stand', 'unable to walk', 'could not walk', 'cant walk', 'can t walk'],
    able: ['can walk', 'nakakalakad', 'able to walk', 'walking', 'makalakad', 'kayang maglakad'],
  },
};

/** First matching trigger phrase with its span, or null. */
function findPhrase(transcript, phrases) {
  for (const phrase of phrases) {
    const hit = findPhraseSpan(transcript, phrase);
    if (hit) return { quote: hit.quote.slice(0, 120), start: hit.start, end: hit.end };
  }
  return null;
}

function oppositeOf(key, value) {
  if (key === 'breathing') return value === 'normal' ? ['absent', 'abnormal'] : value === 'unknown' ? [] : ['normal'];
  if (key === 'consciousness') return value === 'alert' ? ['unresponsive'] : value === 'unresponsive' ? ['alert'] : [];
  if (key === 'severeBleeding') return value === 'present' ? ['absent'] : value === 'absent' ? ['present'] : [];
  if (key === 'walking') return value === 'able' ? ['unable'] : value === 'unable' ? ['able'] : [];
  return [];
}

const NEGATORS = new Set(['no', 'not', 'without', 'never', 'denies', 'denied', 'hindi', 'di', 'wala', 'walang']);
const NEGATION_FILLERS = new Set(['po', 'ho', 'na', 'naman', 'talaga', 'rin', 'din', 'siya', 'siyang', 'niya', 'niyang']);

function isNegatedPhrase(transcript, hit) {
  const prefix = transcript.slice(Math.max(0, hit.start - 80), hit.start);
  const words = [...prefix.matchAll(/[\p{L}\p{N}]+/gu)].map((match) => match[0].toLowerCase());
  for (let index = Math.max(0, words.length - 3); index < words.length; index++) {
    if (NEGATORS.has(words[index]) && words.slice(index + 1).every((word) => NEGATION_FILLERS.has(word))) return true;
  }
  return false;
}

function transcriptObservation(key, transcript) {
  const matches = Object.entries(CONFIRM[key]).flatMap(([value, phrases]) => {
    const hit = findPhrase(transcript, phrases);
    return hit && !isNegatedPhrase(transcript, hit) ? [{ value, hit }] : [];
  });
  const conflict = matches.some((match, index) => matches.slice(index + 1)
    .some((other) => oppositeOf(key, match.value).includes(other.value)));
  return conflict ? { conflict: true } : matches[0] || null;
}

/** Validate model JSON (observations only) and confirm each claim in the transcript. */
function toValidatedExtraction(modelJson, transcript) {
  const warnings = [];
  const raw = modelJson.observations && typeof modelJson.observations === 'object' && !Array.isArray(modelJson.observations)
    ? modelJson.observations : modelJson;
  if (!raw || typeof raw !== 'object') throw new AiError('invalid-model-schema', 'Model output missing observations', 502);
  const observations = {
    breathing: coerceEnum('breathing', raw.breathing, warnings),
    consciousness: coerceEnum('consciousness', raw.consciousness, warnings),
    severeBleeding: coerceEnum('severeBleeding', raw.severeBleeding, warnings),
    walking: coerceEnum('walking', raw.walking, warnings),
  };
  if (!validateObservations(observations)) {
    throw new AiError('invalid-model-schema', 'Model observations failed schema validation', 502);
  }
  const evidence = {};
  for (const key of Object.keys(ALLOWED)) {
    const reported = transcriptObservation(key, transcript);
    if (reported && reported.conflict) {
      observations[key] = 'unknown';
      evidence[key] = null;
      warnings.push(`Contradictory transcript phrases about ${key}; treated as unknown`);
      continue;
    }
    if (reported) {
      if (observations[key] !== reported.value) {
        warnings.push(`Explicit transcript phrase supports ${key}=${reported.value}; used instead of model output`);
      }
      observations[key] = reported.value;
      evidence[key] = reported.hit.quote;
      continue;
    }
    if (observations[key] === 'unknown') {
      evidence[key] = null;
      continue;
    }
    const hit = findPhrase(transcript, CONFIRM[key][observations[key]] || []);
    if (hit && !isNegatedPhrase(transcript, hit)) {
      evidence[key] = hit.quote;
      // A denial ("no severe bleeding") contains the positive phrase: an opposite
      // match strictly inside the confirming span is the denial itself, not a
      // contradiction. Anything else (including a denial around the claim) conflicts.
      const conflict = oppositeOf(key, observations[key])
        .map((other) => findPhrase(transcript, CONFIRM[key][other] || []))
        .some((opp) => opp && !(opp.start >= hit.start && opp.end <= hit.end));
      if (conflict) {
        evidence[key] = null;
        observations[key] = 'unknown';
        warnings.push(`Contradictory statements about ${key}; treated as unknown`);
      }
    } else {
      evidence[key] = null;
      observations[key] = 'unknown';
      warnings.push(`Unconfirmed claim for ${key} was treated as unknown (no transcript evidence)`);
    }
  }
  const uncertainties = [];
  for (const [key, val] of Object.entries(observations)) {
    if (val === 'unknown') uncertainties.push(`${key} was not clearly reported`);
  }
  uncertainties.push('Extracted observations require qualified verification');
  return { observations, evidence, uncertainties: uncertainties.slice(0, 30), warnings: warnings.slice(0, 10) };
}

/** Reference-only term translations; never evidence of a finding. */
function glossaryNote(glossary) {
  if (!glossary.length) return '';
  const lines = glossary.map((g) => `- ${g.matched} = ${g.english}`);
  return `\nReference glossary (word meanings only, not patient evidence; do not infer findings from it):\n${lines.join('\n')}`;
}

async function callOllama(transcript, { timeoutMs, model, ollamaUrl, fetchImpl = fetch, glossary = [] } = {}) {
  const cfg = aiConfig();
  const url = `${ollamaUrl || cfg.ollamaUrl}/api/chat`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs || cfg.timeoutMs);
  try {
    const res = await fetchImpl(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: controller.signal,
      body: JSON.stringify({
        model: model || cfg.model,
        think: false,
        stream: false,
        format: 'json',
        messages: [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user', content: `Transcript (untrusted quoted speech, Tagalog/English/Taglish):\n"""${transcript}"""${glossaryNote(glossary)}` },
        ],
        options: { temperature: 0, num_predict: 128, num_thread: cfg.numThreads },
      }),
    });
    if (!res.ok) {
      if (res.status === 404) throw new AiError('model-missing', `Ollama has no model "${model || cfg.model}"`, 502);
      if (res.status === 503) throw new AiError('runtime-busy', 'Local inference capacity is busy; retry this request', 503);
      throw new AiError('ollama-error', `Ollama replied with status ${res.status}`, 502);
    }
    const data = await res.json().catch(() => {
      throw new AiError('invalid-ollama-response', 'Ollama returned a non-JSON reply', 502);
    });
    const content = data && data.message && typeof data.message.content === 'string' ? data.message.content : '';
    if (data && data.error && /model/i.test(String(data.error))) {
      throw new AiError('model-missing', `Ollama has no model "${model || cfg.model}"`, 502);
    }
    if (!content.trim()) throw new AiError('empty-model-response', 'Model returned an empty response', 502);
    if (data.done !== true || data.done_reason !== 'stop' || !Number.isSafeInteger(data.eval_count) || data.eval_count < 1
      || data.model !== (model || cfg.model)) {
      throw new AiError('incomplete-model-response', 'Local model did not complete token generation', 502);
    }
    return content;
  } catch (err) {
    if (err instanceof AiError) throw err;
    if (err && (err.name === 'AbortError' || err.name === 'TimeoutError')) {
      throw new AiError('ollama-timeout', 'Local AI timed out; capture remains available offline', 504);
    }
    const msg = err && err.message ? err.message : String(err);
    if (/fetch failed|ECONNREFUSED|ENOTFOUND|EHOST|ETIMEDOUT|network/i.test(msg)) {
      throw new AiError('ollama-unreachable', 'Local AI is unreachable; is Ollama running?', 503);
    }
    throw new AiError('inference-failed', 'Local AI inference failed', 502);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Full pipeline: validate input -> Ollama -> validate + ground ->
 * deterministic provisional triage (advisory only).
 */
function injuryLabels(o) {
  const injuries = [];
  if (o.breathing === 'absent') injuries.push('Not breathing');
  else if (o.breathing === 'abnormal') injuries.push('Difficulty breathing');
  if (o.consciousness === 'unresponsive') injuries.push('Unconscious');
  if (o.severeBleeding === 'present') injuries.push('Severe bleeding');
  if (o.walking === 'unable') injuries.push('Non-ambulatory');
  if (o.walking === 'able') injuries.push('Ambulatory');
  return injuries;
}

function extractedField(id, kind, name, value, unit, excerpt) {
  if (value == null || !excerpt) return null;
  return { id, kind, name, value, unit, source: 'model-inferred', excerpt, contradictory: false };
}

async function extractEmergency(transcript, provenanceInput = {}, opts = {}) {
  const cfg = aiConfig();
  const manifest = await localModel(opts.fetchImpl || fetch, opts);
  const { matches, retrieval } = glossaryFor(transcript);
  const raw = await callOllama(transcript, { ...opts, glossary: matches, model: opts.model || cfg.model, ollamaUrl: opts.ollamaUrl || cfg.ollamaUrl });
  const modelJson = extractJsonObject(raw);
  const { observations, evidence, uncertainties, warnings } = toValidatedExtraction(modelJson, transcript);
  const intake = extractReportFields(transcript, knowledgeIndex(), injuryLabels(observations));
  const observationFindings = Object.entries(observations).flatMap(([name, value]) => value === 'unknown' ? [] : [{
    id: `observation-${name}`, kind: 'observation', name, value, unit: null,
    source: 'model-inferred', excerpt: evidence[name], contradictory: false,
  }]);
  const terminologyFindings = intake.findings.filter((finding) =>
    !(finding.name === 'Shortness of breath' && observations.breathing === 'abnormal')
    && !(finding.name === 'Can walk' && observations.walking === 'able'));
  const fieldFindings = [
    extractedField('field-patient-count', 'patient', 'Patient count', intake.fields.patientCount, null, intake.evidence.patientCount),
    extractedField('field-age-group', 'patient', 'Age group', intake.fields.ageGroup === 'Unspecified' ? null : intake.fields.ageGroup, null, intake.evidence.ageGroup),
    extractedField('field-location', 'incident', 'Pickup location', intake.fields.location, null, intake.evidence.location),
    extractedField('field-arrival-eta', 'incident', 'Arrival ETA', intake.fields.etaMinutes, 'minutes', intake.evidence.etaMinutes),
    extractedField('field-symptom-duration', 'symptom', 'Symptom duration', intake.fields.symptomDuration?.value,
      intake.fields.symptomDuration?.unit || null, intake.evidence.symptomDuration),
  ].filter(Boolean);
  const device = cleanDevice(provenanceInput.device);
  const processing = {
    version: 1,
    originalTranscript: transcript,
    observations,
    findings: [...observationFindings, ...terminologyFindings, ...fieldFindings],
    evidence: Object.fromEntries(Object.entries(evidence).filter(([, quote]) => quote !== null)
      .map(([key, excerpt]) => [key, { source: 'model-inferred', excerpt, contradictory: false }])),
    uncertainties,
    provenance: {
      device,
      sttEngine: textOr(provenanceInput.sttEngine, device === 'hospital-browser' ? 'typed/hub-form' : 'device-stt'),
      sttRuntime: textOr(provenanceInput.sttRuntime, 'hub-ai-v1'),
      extraction: { model: manifest.model, revision: manifest.revision, runtime: 'ollama',
        artifactSha256: manifest.sha256, execution: 'local' },
    },
  };
  const provisional = assessRisk(observations);
  // What the hospital's existing legacy finding rules say about these injury terms.
  // Preview only: the dashboard never saves AI-derived injury terms automatically, and
  // higher urgency is never lowered.
  const legacy = riskForRow({ injuries: intake.fields.injuries, triage: 'Unassessed' });
  return {
    processing,
    evidence,
    warnings,
    retrieval,
    fields: intake.fields,
    fieldEvidence: intake.evidence,
    fieldNotes: intake.notes,
    locationBasis: intake.locationBasis,
    legacy: { triage: legacy.effective_triage, reason: legacy.risk_reason, version: legacy.rule_version },
    provisional: { ...provisional, requiresVerification: true, advisoryOnly: true },
    model: opts.model || cfg.model,
    promptVersion: cfg.promptVersion,
  };
}

async function triageAssist(transcript, provenanceInput = {}, opts = {}) {
  const result = await extractEmergency(transcript, provenanceInput, opts);
  // Draft mapping into the legacy report vocabulary (deterministic, reviewable).
  return {
    ...result,
    draft: {
      injuries: result.fields.injuries,
      triage: result.provisional.triage, // provisional only; clinician must confirm
      provisional: true,
    },
    disclaimer: 'Advisory extraction only. Deterministic rules and qualified verification govern triage; this output never declares death or diagnosis.',
  };
}

async function localModel(fetchImpl = fetch, opts = {}) {
  const cfg = aiConfig();
  const base = opts.ollamaUrl || cfg.ollamaUrl;
  const url = new URL(base);
  const host = url.hostname;
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password
    || !((isIP(host) === 4 && /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host))
      || ['localhost', '[::1]', 'ollama', 'host.docker.internal'].includes(host))) {
    throw new AiError('nonlocal-runtime', 'Configure a local Ollama runtime', 503);
  }
  let manifest;
  try { manifest = await verifyModel(); }
  catch (error) { throw new AiError(error.message, 'Local Qwen artifact verification failed; run setup', 503); }
  if ((opts.model || cfg.model) !== manifest.ollamaModel) throw new AiError('model-identity-mismatch', 'Configured model differs from the pinned Qwen artifact', 503);
  try {
    const res = await fetchImpl(`${base}/api/show`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: manifest.ollamaModel }),
      signal: AbortSignal.timeout(cfg.statusTimeoutMs),
    });
    if (!res.ok) throw new AiError(res.status === 404 ? 'model-missing' : 'ollama-error', 'Local Qwen import is not ready; inspect model-init and Ollama logs', 503);
    const data = await res.json();
    if (data.model_info?.['general.architecture'] !== 'qwen3'
      || !new RegExp(`^FROM .*sha256[-:]${manifest.sha256}\\s*$`, 'm').test(data.modelfile || '')) {
      throw new AiError('model-identity-mismatch', 'Ollama weights differ from the verified repository artifact', 503);
    }
  } catch (error) {
    if (error instanceof AiError) throw error;
    throw new AiError('ollama-unreachable', 'Local Ollama model verification failed', 503);
  }
  return manifest;
}

async function aiHealth(fetchImpl = fetch) {
  const result = { contractVersion: 1, state: 'INITIALIZING', status: 'unavailable', model: 'qwen3:0.6b', runtime: 'ollama', model_loaded: false, inference_available: false };
  try {
    const cfg = aiConfig();
    result.model = cfg.model;
    await localModel(fetchImpl);
    result.model_loaded = true;
    // Readiness requires fresh completed tokens, not merely a tag or an allocated runner.
    const res = await fetchImpl(`${cfg.ollamaUrl}/api/generate`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: cfg.model, prompt: 'Reply OK. /no_think', think: false, stream: false, options: { num_predict: 8, num_thread: cfg.numThreads } }),
      signal: AbortSignal.timeout(cfg.timeoutMs),
    });
    const data = await res.json();
    if (!res.ok || data.model !== cfg.model || data.done !== true || data.done_reason !== 'stop'
      || !Number.isSafeInteger(data.eval_count) || data.eval_count < 1
      || typeof data.response !== 'string' || !data.response.trim()) throw new AiError('inference-failed', 'Readiness generation failed');
    return { ...result, state: 'READY', status: 'ready', inference_available: true };
  } catch (error) {
    const code = error.code || (error.name === 'TimeoutError' ? 'ollama-timeout' : 'ollama-unreachable');
    let state = ['model-file-missing', 'model-size-mismatch', 'model-manifest-missing', 'model-missing'].includes(code) ? 'MODEL_MISSING'
      : ['ollama-unreachable', 'ollama-timeout'].includes(code) ? 'UNAVAILABLE' : 'ERROR';
    if (state === 'MODEL_MISSING') {
      try {
        const provisioning = JSON.parse(fs.readFileSync(path.join(process.env.QWEN_MODEL_DIR || path.join(__dirname, '../models/qwen3-0.6b'), 'provisioning.json')));
        if (['INITIALIZING', 'MODEL_DOWNLOADING', 'MODEL_LOADING', 'ERROR'].includes(provisioning.state)) state = provisioning.state;
      } catch {}
    }
    return { ...result, state, error: code };
  }
}

async function aiStatus(fetchImpl = fetch) {
  let cfg;
  try { cfg = aiConfig(); } catch { const health = await aiHealth(fetchImpl); return { ...health, ok: true, available: false, modelAvailable: false }; }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), cfg.statusTimeoutMs);
  try {
    const res = await fetchImpl(`${cfg.ollamaUrl}/api/tags`, { signal: controller.signal });
    if (!res.ok) return { contractVersion: 1, state: 'ERROR', ok: true, available: false, model: cfg.model, modelAvailable: false, error: 'ollama-error', promptVersion: cfg.promptVersion, maxTranscript: cfg.maxTranscript };
    const data = await res.json().catch(() => ({}));
    const names = Array.isArray(data.models) ? data.models.map((m) => String(m.name || m.model || '')) : [];
    const modelAvailable = names.includes(cfg.model);
    const health = await aiHealth(fetchImpl);
    return {
      ...health,
      state: !modelAvailable && health.state === 'READY' ? 'MODEL_MISSING' : health.state,
      contractVersion: 1,
      ok: true,
      available: modelAvailable && health.inference_available === true,
      inference_available: modelAvailable && health.inference_available === true,
      model: cfg.model,
      modelAvailable,
      modelsSeen: names.length,
      error: modelAvailable ? health.error || null : 'model-missing',
      promptVersion: cfg.promptVersion,
      maxTranscript: cfg.maxTranscript,
    };
  } catch {
    return { contractVersion: 1, state: 'UNAVAILABLE', ok: true, available: false, model: cfg.model, modelAvailable: false, error: 'ollama-unreachable', promptVersion: cfg.promptVersion, maxTranscript: cfg.maxTranscript };
  } finally {
    clearTimeout(timer);
  }
}

module.exports = {
  aiConfig,
  AiError,
  PROMPT_VERSION,
  SYSTEM_PROMPT,
  validateTranscriptInput,
  extractJsonObject,
  toValidatedExtraction,
  callOllama,
  extractEmergency,
  triageAssist,
  aiStatus,
  aiHealth,
  localModel,
  glossaryFor,
  glossaryNote,
  knowledgeIndex,
};
