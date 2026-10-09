# Shared local-AI contract (web, mobile, watch)

Source: `hub/ai.js`, `hub/server.js`, `hub/risk.js`, `hub/public/hub-client.js`, `hub/public/dashboard.js`,
`watch/lib/services/ai_service.dart`, `watch/apple/Sources/VanguardApple/AiContract.swift`.
Synthetic data only. Qwen is an extraction assistant, never the triage authority.

## Endpoints (same origin as the hub)

| Method/path | Purpose |
| --- | --- |
| `GET /api/ai/health` | Verified local artifact/import identity and fresh token generation; 200 ready or 503 unavailable. |
| `POST /api/triage/:id/ai-extract` | Extract current stored transcript and append an immutable, idempotent revision. |
| `GET /api/ai/status` | Can the hub reach Ollama, and is the configured model listed? |
| `POST /api/ai/extract` | Transcript in, validated observations + evidence + deterministic provisional triage out. |
| `POST /api/ai/triage-assist` | Same as extract, plus a reviewable draft (`injuries` string + provisional triage). |
| `POST /api/knowledge/lookup` | `{ transcript }` in, matched Filipino/English terminology entries out. 503 `knowledge-unavailable` if the pack is not loaded. |

The legacy Flutter preview client calls the hub routes. Native Apple capture now uses local llama.cpp first, with optional paired-iPhone fallback. Apple devices never call Ollama directly. `127.0.0.1`
on a watch or phone means that device itself. Save a configured hospital LAN origin
in the Apple app, such as `http://<hub-hostname>.local:3000`, and pair an assigned
access token. Native capture never consults Docker/HTTP AI readiness. Flutter is a
legacy hub-preview client with explicit `HUB_URL`/`HUB_TOKEN`; it is not the native
Apple implementation. See `global-ai-connectivity.md` for pairing and discovery limits.

All API requests use UUID `X-Request-ID` correlation. AI responses add
`contractVersion: 1` and the corresponding `requestId`; existing fields remain
compatible. Processing and sync formats retain their existing version/identity.
The shared `fixtures/ai-v1.json` is validated by hub tests and decoded by both Swift
preview and native-processing types without losing extraction provenance/evidence.

## Request

```json
{
  "transcript": "Synthetic patient is awake, breathing normally, no severe bleeding, can walk.",
  "device": "hospital-browser",
  "sttEngine": "typed/hub-form",
  "sttRuntime": "hub-ai-v1"
}
```

| Field | Rule |
| --- | --- |
| `transcript` | Required non-empty string, max 4000 chars (env `AI_MAX_TRANSCRIPT`). Original speech, kept exact. |
| `device` | One of `hospital-browser`, `iphone`, `apple-watch`, `wear-os`. Anything else becomes `hospital-browser`. |
| `sttEngine`, `sttRuntime` | Optional strings, max 100 chars. Defaults describe the sender. |

Flutter sends `{ transcript, device }`. Swift sends the same JSON via `AiRequest`.

## Success response (`200 { ok: true, ... }`)

```json
{
  "ok": true,
  "processing": {
    "version": 1,
    "originalTranscript": "Synthetic patient is awake, breathing normally, no severe bleeding, can walk.",
    "observations": {
      "breathing": "normal",
      "consciousness": "alert",
      "severeBleeding": "absent",
      "walking": "able"
    },
    "uncertainties": ["Extracted observations require qualified verification"],
    "provenance": {
      "device": "hospital-browser",
      "sttEngine": "typed/hub-form",
      "sttRuntime": "hub-ai-v1",
      "extraction": {"model":"Qwen3-0.6B","revision":"50968a4468ef4233ed78cd7c3de230dd1d61a56b","runtime":"ollama","artifactSha256":"ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a","execution":"local"}
    }
  },
  "evidence": {
    "breathing": "breathing normally",
    "consciousness": "awake",
    "severeBleeding": "no severe bleeding",
    "walking": "can walk"
  },
  "warnings": [],
  "provisional": {
    "triage": "Minor",
    "reason": "Walking, alert, normal breathing, no severe bleeding reported",
    "version": "provisional-v1",
    "requiresVerification": true,
    "advisoryOnly": true
  },
  "model": "qwen3:0.6b",
  "promptVersion": "vanguard-extract-v2"
}
```

`triage-assist` adds:

```json
{
  "draft": {
    "injuries": "Ambulatory",
    "triage": "Minor",
    "provisional": true
  },
  "disclaimer": "Advisory extraction only. Deterministic rules and qualified verification govern triage; this output never declares death or diagnosis."
}
```

Rules every client can rely on:

- `observations` always has all four keys. Allowed values are fixed in
  `hub/risk.js`: breathing `normal|abnormal|absent|unknown`, consciousness
  `alert|unresponsive|unknown`, severeBleeding `present|absent|unknown`,
  walking `able|unable|unknown`. Unsupported model enums become `unknown`; a
  supported transcript phrase may independently recover the observation.
- `unknown` never means absent or normal. Supported explicit transcript phrases
  can recover an observation when the model misses or mislabels it; the exact
  excerpt is retained. Negated or conflicting phrases remain `unknown`. A
  non-unknown claim without an exact transcript excerpt becomes `unknown` with a
  warning.
- `provisional` comes from deterministic `assessRisk`, not from the model.
  `requiresVerification` and `advisoryOnly` are always true. The model never
  assigns urgency, declares death, or diagnoses.
- `processing.provenance.extraction` records the verified repository artifact and imported local Ollama blob. `processing.evidence` carries source/excerpt/contradiction references labeled model-inferred; the older top-level evidence strings stay compatible.
- Preview routes remain advisory. The web outbox saves originals before inference, automatically sends Unassessed reports through `/api/sync-triage`, and retains failed receipts. Alternatively invoke `/api/triage/:id/ai-extract` for a current persisted report. No review checkbox gates storage; generated claims remain unverified in clinical assessment.
- The Flutter client (`AiService`) re-validates every reply and rejects it as AI
  unavailable if any of these hold: an observation is outside the enums above, the
  `provisional.triage` is not `Immediate|Unassessed|Delayed|Minor`, either
  `requiresVerification` or `advisoryOnly` is not true, `originalTranscript`
  differs from the sent transcript, or a non-null `extraction` lacks nonblank
  model/revision/runtime, a 64-lowercase-hex `artifactSha256` and
  `execution: "local"`. Missing observation keys stay `unknown`. Swift
  `AiContract` preserves provenance/evidence and downgrades unsupported observation enums to unknown; complete native processing validation occurs in `NativeProcessing`.

## Offline terminology retrieval (RAG)

Extraction responses add `retrieval: { packId, packVersion, reviewStatus, entryCount, matches[] }`
(`null` when disabled). Each match is `{ id, matched, filipino, english, medicalTerm, category, negated }`.
`negated` is true when a denial word ("no", "not", "walang", "hindi") directly precedes the phrase.
The response lists every match; the prompt gets one meaning per phrase and omits negated ones.

- The pack is `hub/rag/medical_terms.json` (override with `RAG_KNOWLEDGE_FILE`; disable
  with `RAG_ENABLED=0`). It is indexed into an in-memory SQLite FTS5 table at first use,
  so there is no network call and no change to `vanguard.db`.
- Matched terms are appended to the Qwen prompt as a word-meaning glossary labeled "not
  patient evidence". They never confirm a finding: observations still require an exact
  transcript excerpt, and provisional triage still comes only from `assessRisk`.
- The shipped pack (`0.3.0-draft`) has about 1,200 entries across anatomy, symptoms, signs,
  injuries, mechanisms of injury, conditions and history. Its Filipino/English translations
  were written by the development team from general knowledge, not taken from a clinical
  source, and may be wrong or incomplete. Where Filipino rescuers normally use the English
  word, the `filipino` field is that English word. Phrases that match ordinary speech
  (for example "back", "yes", "left") are deliberately excluded.
- Matching is whole-phrase: a misspelling or an unlisted word form will not match, but
  Tagalog clitics, linkers and politeness particles may appear between a phrase's words
  without breaking it ("nahihirapan siyang huminga" still matches "nahihirapan huminga").
  Negators and content words still break the match. A phrase inside a longer matched
  phrase is not reported separately; entries that share the same phrase are all returned.
  At most five terms go into the prompt. The glossary can influence what the model writes,
  but every finding still needs a verbatim transcript excerpt, so it cannot add a finding
  the transcript does not state.
- Pack entries may contain only `id, phrases, filipino, english, medicalTerm, category`
  (`category` is symptom, sign, injury, mechanism, condition, anatomy or history);
  urgency, triage or guideline fields are rejected at load, and an invalid pack disables
  retrieval (extraction continues without a glossary).
- The shipped pack is `reviewStatus: "unreviewed-draft"`: starter vocabulary not reviewed
  by a clinician or translator. No clinical guidelines or protocols are shipped. Supply
  those only from an authoritative, versioned, clinician-reviewed source.
- Retrieval runs in the hub only. The Apple/watch apps do not yet ship or search a pack.
- Prompt version is `vanguard-extract-v2` (v1 had no glossary).

## Prefilled report fields

Extraction and triage-assist responses also carry `fields` (`location`, `patientCount`,
`ageGroup`, `etaMinutes`, `symptomDuration`, `injuries`), `fieldEvidence` (the exact transcript text each value
came from), `fieldNotes`, `locationBasis` (`explicit` for Barangay/Purok/Sitio, `inferred`
for an "in/sa/near X" guess) and `legacy` (`{ triage, reason, version }`).

- Implemented in `hub/intake.js` with plain pattern matching and the terminology pack. No
  model output is used for these fields, nothing is invented, and unstated values stay `null`
  (`ageGroup` stays `Unspecified`). Values are limited to what the hub's report validator
  accepts (count 1-99, ETA 1-720 minutes, injuries up to 300 characters).
- ETA needs an arrival cue next to the minutes ("ETA", "away", "out", "papunta"); a duration
  such as "unconscious for 10 minutes" is not an ETA. Ages map to Infant (under 1 year),
  Child (1-12), Adult (18-59) and Elderly (60+); 13-17 and mixed groups stay unspecified.
- `symptomDuration` is a separate `{ value, unit }` field, with exact `fieldEvidence`; it
  requires an onset/duration cue such as "for", "ago", or Tagalog "na" and is never used as ETA.
- Location is the least reliable field. An inferred location is only a guess and the dashboard
  says so. Roofs, stairs, body parts, hospitals and conditions are rejected, but the reviewer
  must still check it.
- `injuries` lists the labels from the four validated findings first, then non-denied
  pack terms in the injury, condition, mechanism and symptom categories.
- The AI processing envelope also saves evidence-backed observations, terminology matches,
  patient fields, ETA and symptom duration in `processing.findings`. The report detail shows
  them as **unverified** with transcript excerpts. They do not overwrite the legacy `injuries`
  field or establish the saved report's clinical priority.
- `legacy` is the hospital's existing legacy finding rules (`riskForRow`) applied to those
  injury terms as they would be saved with triage `Unassessed`. Those rules can raise urgency
  (for example "Chest pain", "Head injury", "Drowning" are Immediate) but never lower it. It is
  a preview: the dashboard never saves AI-derived injury terms automatically, and the pack's terms are unreviewed.
- The dashboard keeps the offline-first flow: the typed original is stored locally before Qwen
  runs and is sent automatically as `Unassessed`. After extraction it fills only **blank**
  location, patient count, age group and ETA from `fields` (anything the person typed wins, and
  a guessed `inferred` location is shown but not saved), stores that version, then sends it.
  The evidence quote for each filled value is shown. `injuries` is saved as typed, otherwise
  `Unspecified`: transcript terms remain in the unverified processing findings and are shown
  as suggestions with the legacy-rule preview, but are not promoted to the legacy field or
  used to establish priority before a person reviews the report.

## Draft board setups

`hub/public/setups.json` maps about 470 pack terms to "get ready" resource labels (for example
Concussion: CT / neurosurgery, Neuro obs). It lists rooms, teams and equipment only, never
treatments, doses or urgency, and is marked `unreviewed-draft`. The board loads it optionally;
the hospital's own `PREP` table in `dashboard.js` always wins, and the board shows a notice when
a checklist uses draft setups.

Limit: because injuries are saved as `Unspecified` unless typed, AI-saved reports currently get
no draft suggestions either. The board shows no readiness checklist for a report whose findings are not current, which
includes any report saved with AI processing (`source_findings_current` is false). So these
setups appear for reports without attached AI processing, not yet for ones saved from the AI
panel. Changing that is a clinical-safety decision tracked in the architecture notes.

## Status response

```json
{
  "ok": true,
  "contractVersion": 1,
  "state": "READY",
  "available": true,
  "model": "qwen3:0.6b",
  "modelAvailable": true,
  "modelsSeen": 1,
  "error": null,
  "promptVersion": "vanguard-extract-v2",
  "maxTranscript": 4000
}
```

`available` now requires verified artifact/import identity and actual completed,
nonempty token generation. A matching tag alone is insufficient. Both health and
status expose `state`: `INITIALIZING`, `MODEL_MISSING`, `MODEL_DOWNLOADING`,
`MODEL_LOADING`, `READY`, `UNAVAILABLE` or `ERROR`. Provisioning progress comes from
the verified-weights initializer. Health retains its legacy lowercase `status` and
booleans. `AI Live` requires `READY` and `inference_available === true`. Concurrent
health polls share one in-flight probe, never patient input. Native `QwenEngine.state`
is READY only after real local tokens. Apple screens display local AI and LAN hub
states separately; a LAN error never changes engine readiness.

## AI errors (original capture/outbox remains intact)

| HTTP | `error` | Meaning |
| --- | --- | --- |
| 400 | `invalid-transcript` | Missing or empty transcript. |
| 400 | `transcript-too-long` | Over `AI_MAX_TRANSCRIPT`. Shorten and retry; the report stays local. |
| 502 | `model-missing` | Ollama is up but has no `qwen3:0.6b`. Inspect `model-init`/Ollama logs and retry Compose provisioning; host developers can use `qwen-setup.sh host`. |
| 503 | `ollama-unreachable` | Start the internal Ollama container; capture stays local. |
| 504 | `ollama-timeout` | One bounded call per request, no retries. Shorten the transcript and retry. |
| 502 | `invalid-model-json`, `empty-model-response`, `invalid-model-schema`, `inference-failed` | Unusable model reply. Nothing was stored. |

Error shape: `{ ok: false, contractVersion: 1, requestId, error, message }`. Invalid configuration and runtime capacity failures also return actionable `invalid-runtime-url`, `invalid-ai-config` or `runtime-busy` errors. Transcripts are never logged;
the hub logs only the error code and transcript length.

## Availability states

- Web inference uses only the configured backend and internal Docker Ollama. Without
  internet, existing model volumes/images still support inference. Initial provisioning
  may need internet; capture retains an Unassessed original if extraction fails.
- Apple Watch and iPhone execute local packaged Qwen independently. A missing native
  model or hardware budget failure is a local AI error; disconnected LAN is a separate
  transport state. Watch audio can use the existing paired-iPhone offline fallback.
- Native/Flutter outboxes retain reports across network errors and advance only on
  validated ACKs. Web outboxes use distinct per-report keys per authenticated account
  (or a synthetic browser UUID), preventing another capture from replacing the queue.
- Each Ollama call contains only the fixed system prompt and that request's transcript;
  no shared user messages, continuation contexts or response slots are used. Ollama
  executes one request at a time by default with an eight-request queue. CPU threads
  are bounded by `AI_NUM_THREADS` (default two); timeouts/busy errors retain originals.

## Native and persisted integration

See `QWEN_INTEGRATION.md` for native iOS/watchOS CPU inference, model packaging,
SQLite-first capture, bounded Watch Connectivity fallback and per-platform evidence.
Both simulators generated tokens independently; physical-device behavior remains
unverified. Watch voice processing now runs bundled multilingual Whisper STT before
the optional paired-iPhone fallback. Qwen remains text-only.

Persisted extraction takes `{requestId: UUID, baseRevision: integer}` at
`POST /api/triage/:id/ai-extract`. It uses the current stored transcript, appends
machine provenance/evidence and returns the updated report. Identical retries are
idempotent; stale/concurrent corrected revisions return 409. Originals and prior
corrections remain unchanged. Native/LLM failures retain pending capture/history.

No browser-native Qwen, new cloud dependency, BLE or React replacement is claimed.
