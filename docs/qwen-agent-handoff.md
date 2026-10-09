# Qwen implementation handoff for the teammate's agent

> Backend integration update, 2026-10-09: the current request supersedes the
> database deferral below. Structured intake, SQLite v2, corrections/overrides and
> patient/encounter history are now implemented. Read `api-contract.md` and
> `backend-completion.md` for the live contract; remaining Apple/Qwen runtime work
> is still unimplemented. The material below records the earlier handoff.

User ownership decision, 2026-10-09: your teammate owns **all Qwen runtime/model
implementation**. A separate teammate owns **database implementation**. This
branch implements surrounding application behavior and integration contracts.
No Qwen weights, runtime, cloud fallback or fabricated inference outputs are
included. Read `AGENTS.md`, `architecture.md`, `api-contract.md`, and
`database-team-handoff.md` before editing.

## Objective and boundaries

Execute **Qwen/Qwen3-0.6B locally** on Apple Watch, iPhone and the hospital browser.
Extract only facts explicitly present in a preserved transcript; emit uncertainty
for omissions, conflicts and negation. Model output must never assign urgency,
declare death, prescribe treatment, invent the final triage template or supply
missing observations. Deterministic rules and qualified clinician verification
govern provisional risk. Do not replace Watch-local execution with iPhone/cloud
execution and call the Watch gate passed.

Keep `watch/`, `hub/`, Express, SQLite, Docker and the Wear OS implementation.
Add native implementation under `watch/apple`; hospital runtime assets belong
under the existing `hub/public` feature boundary. Do not add an inference server,
new container, dashboard framework or remote API. Coordinate with the database
owner before sending extended reports: the current receiver explicitly rejects
`processing` metadata rather than acknowledging data it cannot store.

## Start with measurable feasibility gates

1. Pin an upstream Qwen model revision and a compatible native runtime commit.
   Inspect the runtime's actual supported platforms. Treat CPU-only watchOS
   cross-compilation as a feasibility experiment, not proven support. The
   [llama.cpp project](https://github.com/ggml-org/llama.cpp) is a candidate to
   evaluate; its generic Apple support is not evidence of Watch execution.
2. On a **physical Watch**, load a verified quantized artifact and generate new
   tokens from two different synthetic prompts with phone/network disconnected.
   Measure peak resident memory, first-token latency, tokens/sec, total latency,
   watchdog/thermal behavior and battery use. Record cold and warm attempts and
   cancellation. Build/download success does not pass this gate.
3. Repeat independently on a physical iPhone. Test offline model absence,
   corruption, memory pressure and interrupted generation. Fail explicitly;
   retain the audio/transcript queue without substituting a cloud request.
4. In a Windows browser, evaluate a compatible ONNX/WebGPU or WASM artifact and
   runtime. Verify actual text generation with WAN disabled and all runtime/model
   resources served locally. A CPU WASM fallback is acceptable only if measured;
   an unsupported backend must show a real blocker.

Apple Watch STT is a **separate** gate. The installed Xcode 27 watchOS SDK has no
Speech.framework. Apple's current
[SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/)
excludes Watch from SpeechTranscriber support. Qwen3-0.6B is the text extraction
model in this design, not the transcription runtime. Coordinate a separately
proven offline Watch STT runtime; do not conflate it with Qwen3-ASR.

## Existing code to use

| Boundary | Implemented integration point | Your work |
| --- | --- | --- |
| iPhone STT | `watch/apple/Sources/VanguardApple/OnDeviceTranscriber.swift` | Invoke only after speech permission; `requiresOnDeviceRecognition` is mandatory; an unavailable locale fails locally |
| Recovery | `FallbackProcessor.swift`: `OfflineCaptureProcessor.process(_:)` | Implement real STT → Qwen extraction, returning the exact transcript plus validated processing JSON |
| Durable processing | `FallbackRepository.commitProcessed(...)` | Coordinate implementation with database owner; atomic SQLite transcript/provenance/outbox commit, no transport before commit |
| Hospital metadata | `hub/processing.js`: `validateProcessing(value)` | Validate in the receiver after durable schema integration; currently a tested contract utility, not a live ingest capability |
| Structured risk | `hub/risk.js`: `validateObservations`, `assessRisk` | Model observations feed these pure functions after validation; never use model-provided category |
| Current priority | `riskForRow` | Existing legacy exact-finding rules remain until structured persistence is integrated; do not discard original source category |
| Presentation | `hub/public/index.html` | Preserve safe `textContent`, original evidence, rule explanation, uncertainty and clinician verification |

`OfflineCaptureProcessor` has no production implementation or default fixture.
Its test fixture checks recovery state only. Do not ship that fixture as an AI
implementation. The Apple package is a library; complete native app targets,
WatchConnectivity transfer and durable capture intake still need integration.

## Processing envelope v1

This is an extraction/evidence contract, **not the final clinical template**.
Attach it as the additive `processing` field of the existing report after the
database owner enables durable storage. Keep `watchId`, `localId`, `createdAt`
and existing report fields compatible. Do not generate a new timestamp/identity
when the phone retries a Watch capture.

```json
{
  "version": 1,
  "originalTranscript": "Synthetic patient is unresponsive. Breathing was not assessed.",
  "observations": {
    "breathing": "unknown",
    "consciousness": "unresponsive",
    "severeBleeding": "unknown",
    "walking": "unknown"
  },
  "uncertainties": ["Breathing, bleeding and walking were not assessed", "Extracted observations require qualified verification"],
  "provenance": {
    "device": "iphone",
    "sttEngine": "SFSpeechRecognizer/on-device",
    "sttRuntime": "ACTUAL_OS_BUILD_FROM_DEVICE",
    "extraction": {
      "model": "Qwen3-0.6B",
      "revision": "ACTUAL_IMMUTABLE_UPSTREAM_REVISION",
      "runtime": "ACTUAL_RUNTIME_VERSION_OR_COMMIT",
      "artifactSha256": "REPLACE_WITH_ACTUAL_64_LOWERCASE_HEX_SHA256",
      "execution": "local"
    }
  }
}
```

The placeholders above are documentation only; checksum placeholders fail the
validator. Never fabricate provenance values. `extraction: null` is valid for
non-LLM processing, but does not establish Qwen execution.

Allowed observation values are fixed in `hub/risk.js`; all four keys are required.
Unknown never means negative/normal. Limit originals to 16,000 characters and
uncertainties to 30 entries of 300 characters. Over-limit text stays preserved in
the local queue; reject/report the limit rather than silently shortening it.
The legacy `rawText` storage limit is 1,000 characters until the database owner
upgrades it. `originalTranscript` must remain exact and immutable. Corrections
are separate audit events with actor, reason, time and provenance.

The validator establishes shape and claimed provenance, **not semantic truth**.
Add a tested grounding check before accepting generated observations: retain a
source excerpt for each non-unknown observation and check it against the original
transcript; reject conflicting or unsupported findings as unknown. Agree any
additive evidence field with the database owner and update this shared validator,
native encoding, tests and API documentation together. No model confidence should
be presented as calibrated clinical certainty.

Build the final-template adapter as a pure mapping from the validated extraction
and the existing report fields. Keep it outside runtime/model loading. The final
template is not supplied: implement the current report adapter first; do not
invent additional patient fields, clinical scores or required review/Send steps.

## Prompt and runtime discipline

Use a fixed, versioned extraction instruction and treat the transcript as
untrusted quoted data. Instructions inside speech must not change the schema,
runtime or transport behavior. Output bounded JSON with enum values only. Test
negation, unknown assessments, contradictory speech, Taglish, empty speech,
truncated generation and prompt injection. Parsing failure is an explicit failed
processing attempt; retain original data and retry safely.

Use the pinned Qwen tokenizer/chat template. The
[official model card](https://huggingface.co/Qwen/Qwen3-0.6B) documents
`enable_thinking=False`; verify that the chosen runtime applies the equivalent
template behavior. Bound context/output and cancellation. Record the prompt
version, tokenizer/template hash and generation settings with the test evidence.
Do not guess current versions or hide reasoning/invalid output by hardcoding facts.

## Hospital browser implementation

Keep inference in a Worker so model loading/generation cannot block the board.
Load models and tokenizer/runtime assets from the same local hospital origin.
For a Transformers.js candidate, follow the pinned version's
[local-resource configuration](https://huggingface.co/docs/transformers.js/en/custom_usage)
and [environment API](https://huggingface.co/docs/transformers.js/api/env): enable
local models, disable remote models, and point WASM/MJS resources to local paths.
Vendor the exact JS/worker/WASM files; do not keep CDN imports. Test WebGPU's
secure-context restrictions: localhost can differ from plain HTTP on a LAN IP.
Do not weaken browser security to make a demo pass.

Provisioning may require internet beforehand. During processing there must be
no model/CDN/telemetry/cloud inference requests. Verify a reload with WAN disabled
and cold browser caches while the local hospital stays reachable. If fully offline
browser operation without the hospital host is required later, specify and test
durable browser storage/service-worker behavior separately.

Automatically process new persisted reports; retries/reloads must not create new
patients or duplicate audit events. Preserve a stable extraction attempt ID and
report revision. A database/network outage retains processing state; it never
silently overwrites a clinician correction. Complete the database owner's audited
extraction/correction API before writing machine observations back to the hub.

## Provenance manifest and acceptance evidence

Commit a small manifest with actual values once artifacts have been selected:
upstream URL/revision/license, conversion tool and command, quantization,
SHA-256 and size of **every** weight shard, tokenizer, config, chat template,
runtime JS/WASM/native library, plus runtime commit/version and build flags.
Keep large weights uncommitted; document local provisioning and verify hashes
before loading. Never leave `latest`, unversioned CDN URLs or invented checksums
in a completed implementation.

Record each platform independently:

| Platform | Required evidence |
| --- | --- |
| Watch Simulator | Compile plus runtime attempt, clearly labeled simulated; no hardware/memory claim |
| Physical Watch | Fresh token generation, offline STT separately, resource measurements and OS/device states |
| iPhone Simulator | Independent generation attempt and fallback recovery; simulator locale/model availability recorded |
| Physical iPhone | Offline STT + actual Qwen generation, preserved audio, retry after phone unavailable/restart |
| Hospital browser | Windows/browser/GPU/backend versions, token generation and network request evidence |
| Windows Docker | Backend tests and durable receipt/persistence from `windows-qa.md`; this does not prove browser inference |

Use synthetic fixtures. Keep generated text from test cases separate from logs
containing real transcripts. Include failure/blocked outcomes, not just successes.
Start a feature branch from freshly fetched `origin/main`, preserve uncommitted
work, and prepare a reviewed PR with the model manifest and this evidence. Do not
merge, deploy or change branch protection without the user's instruction.
