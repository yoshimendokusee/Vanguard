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
  "promptVersion": "vanguard-extract-v1"
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
  walking `able|unable|unknown`. Anything else becomes `unknown` with a warning.
- `unknown` never means absent or normal. A non-unknown claim without an exact
  transcript excerpt becomes `unknown` with a warning. Conflicting statements
  become `unknown` with a warning.
- `provisional` comes from deterministic `assessRisk`, not from the model.
  `requiresVerification` and `advisoryOnly` are always true. The model never
  assigns urgency, declares death, or diagnoses.
- `processing.provenance.extraction` records the verified repository artifact and imported local Ollama blob. `processing.evidence` carries source/excerpt/contradiction references labeled model-inferred; the older top-level evidence strings stay compatible.
- Preview routes remain advisory. The web outbox saves originals before inference, automatically sends Unassessed reports through `/api/sync-triage`, and retains failed receipts. Alternatively invoke `/api/triage/:id/ai-extract` for a current persisted report. No review checkbox gates storage; generated claims remain unverified in clinical assessment.

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
  "promptVersion": "vanguard-extract-v1",
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
unverified. Watch offline speech recognition is not implemented. Qwen is not STT.

Persisted extraction takes `{requestId: UUID, baseRevision: integer}` at
`POST /api/triage/:id/ai-extract`. It uses the current stored transcript, appends
machine provenance/evidence and returns the updated report. Identical retries are
idempotent; stale/concurrent corrected revisions return 409. Originals and prior
corrections remain unchanged. Native/LLM failures retain pending capture/history.

No browser-native Qwen, new cloud dependency, BLE or React replacement is claimed.
