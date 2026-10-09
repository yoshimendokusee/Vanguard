# Shared local-AI contract (web, mobile, watch)

Source: `hub/ai.js`, `hub/server.js`, `hub/risk.js`, `hub/public/index.html`,
`watch/lib/services/ai_service.dart`, `watch/apple/Sources/VanguardApple/AiContract.swift`.
Synthetic data only. Qwen is an extraction assistant, never the triage authority.

## Endpoints (same origin as the hub)

| Method/path | Purpose |
| --- | --- |
| `GET /api/ai/status` | Can the hub reach Ollama, and is the configured model listed? |
| `POST /api/ai/extract` | Transcript in, validated observations + evidence + deterministic provisional triage out. |
| `POST /api/ai/triage-assist` | Same as extract, plus a reviewable draft (`injuries` string + provisional triage). |

The watch never calls Ollama directly. It calls these hub routes. `127.0.0.1`
on a watch or phone means that device itself, not the hospital computer. Use the
hub laptop LAN IP (for example `http://192.168.8.10:3000`) and keep the hub and
Ollama on the same hospital computer or LAN. Never expose Ollama to the internet.

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
      "extraction": null
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
- `processing.provenance.extraction` is `null` for this hub path. It does not
  claim on-device weights; never invent a revision or checksum.
- Save through the existing `POST /api/sync-triage` after human review. The AI
  routes never write to SQLite themselves.
- The Flutter client (`AiService`) re-validates every reply and rejects it as AI
  unavailable if any of these hold: an observation is outside the enums above, the
  `provisional.triage` is not `Immediate|Unassessed|Delayed|Minor`, either
  `requiresVerification` or `advisoryOnly` is not true, `originalTranscript`
  differs from the sent transcript, or a non-null `extraction` lacks nonblank
  model/revision/runtime, a 64-lowercase-hex `artifactSha256` and
  `execution: "local"`. Missing observation keys stay `unknown`. Swift
  `AiContract` types do not perform these checks yet.

## Status response

```json
{
  "ok": true,
  "available": true,
  "model": "qwen3:0.6b",
  "modelAvailable": true,
  "modelsSeen": 1,
  "error": null,
  "promptVersion": "vanguard-extract-v1",
  "maxTranscript": 4000
}
```

`available` is false when Ollama is down (`ollama-unreachable`) or the model is
missing (`model-missing`). The board header shows AI ready / AI unavailable and
keeps working either way.

## Errors (nothing is saved)

| HTTP | `error` | Meaning |
| --- | --- | --- |
| 400 | `invalid-transcript` | Missing or empty transcript. |
| 400 | `transcript-too-long` | Over `AI_MAX_TRANSCRIPT`. Shorten and retry; the report stays local. |
| 502 | `model-missing` | Ollama is up but has no `qwen3:0.6b`. Run `ollama pull qwen3:0.6b` on the hub computer. |
| 503 | `ollama-unreachable` | Start Ollama on the hub computer; capture stays local. |
| 504 | `ollama-timeout` | One bounded call per request, no retries. Shorten the transcript and retry. |
| 502 | `invalid-model-json`, `empty-model-response`, `invalid-model-schema`, `inference-failed` | Unusable model reply. Nothing was stored. |

Error shape: `{ ok: false, error, message }`. Transcripts are never logged;
the hub logs only the error code and transcript length.

## Availability states

1. Web app + local Ollama up: full extract and triage-assist flow.
2. Watch or companion reaches the hub: same flow through `AiService` (Flutter)
   or `AiRequest` (Swift). Fails fast on timeout so capture never waits.
3. Watch disconnected: keep recording to local SQLite. Show AI unavailable;
   never claim Qwen processed the report.
4. No internet but LAN up: local inference still works if the device reaches the
   hub computer. Internet and LAN are different things.
5. Hub or Ollama down: graceful error, board and capture keep working.

## What is not claimed

No on-device Qwen on Watch or iPhone in this branch. `watch/apple` holds the
request/response types and the existing STT/recovery library, not a complete
native app, WatchConnectivity transfer, or measured on-device inference. Real
hardware still needs a native target, signing, and the feasibility gates in
`docs/qwen-agent-handoff.md`. No BLE, Supabase, or React dashboard is added.
