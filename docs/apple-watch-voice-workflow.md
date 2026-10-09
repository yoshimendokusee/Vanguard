# Apple Watch voice-report workflow

Status: **current update statically checked only; historical macOS/iOS simulator evidence below does not verify the current pipeline or Apple hardware.**
Every claim below says where it was checked. Nothing here is a clinical validation. The terminology pack and board
setups are unreviewed drafts. LAN credentials are required for non-loopback binding; HTTP and SQLite remain unencrypted
(see `docs/architecture.md`): do not use any of this for real patients.

## What the app does

```
Watch microphone ─▶ CAF audio saved to SQLite-referenced file ─▶ Watch Whisper tiny multilingual (offline)
   ─▶ immutable transcript ─▶ paired iPhone fallback if Watch recognition or extraction fails
   ─▶ local Qwen3-0.6B: four observations (breathing, consciousness, severe bleeding, walking)
   ─▶ confirmation against the transcript (ported hub rules) ─▶ deterministic triage (ported hub rules)
   ─▶ explicit radial-pulse circulation + separate quote-grounded RAG terms
   ─▶ durable report + queue ─▶ direct LAN / optional complete-report iPhone relay
   ─▶ hospital hub SQLite ─▶ valid ACK / return paired receipt ─▶ Sent
```

* **UI** (`watch/apple/Sources/VanguardApple/WatchUI`): focused SwiftUI views over plain values; the result opens automatically, with no Pickup Location or send-confirmation step;
  `WatchRootView` binds them to `VoiceReportController`. The system draws the clock.
* **Business logic** (`VoiceReportController`, `VoiceReportState`): explicit state machine; permission, recording
  with live metering, silence/interruption handling, transcription hook, extraction, triage, corrections, delivery.
  No logic lives in views.
* **Data** (`NativeStore`, migration `0002_voice_workflow.sql`): additive, transactional. Immutable correction
  versions, append-only report-detail revisions, persisted delivery state (the only mutable table).
* **Delivery** (`NativeWorkflow.sync`): `LOCAL_SAVED → QUEUED → TRANSFERRING → AWAITING_RECEIPT → DELIVERED`,
  `RETRY_REQUIRED` after transient failures, `FAILED_PERMANENTLY` only when the hospital explicitly rejects.
  `DELIVERED` is refused by the database unless a stored hospital receipt exists. Retries carry the same report ID
  (`reportId`, `(watch_id, created_at)`), so the hub cannot duplicate a report. Save only holds a report out of the queue.
* **Corrections**: a new transcript version, re-extracted and reassessed locally; after delivery it is sent as a
  `kind: correction` report revision (original submission kept on both sides). Intake retries preserve the first details snapshot;
  newer hospital corrections are never overwritten by an automatically rebased device edit.

## Decisions made from evidence

1. **Qwen3-0.6B only classifies four observations.** A live run with a richer findings schema returned garbled keys
   and hallucinated observations (for example "alert, can walk" for unconscious drowned children). The prompt remains unchanged;
   circulation comes from exact radial-pulse statements. New extraction returns only the five observations plus RAG terms.
2. **A model quote is never trusted.** The old Swift validator accepted any claim whose quote merely occurred in the
   transcript, so an injected sentence could yield `Minor`. It now uses the hub's confirmation phrases (see parity).
3. **Triage is a port, not a second algorithm.** `Triage.swift` mirrors `hub/risk.js`.
4. **The hub treats model-inferred findings as unverified.** Reports from the watch reach the board as `Unassessed`
   until a person verifies them, even when the watch screen shows a provisional `High priority`. This is the existing
   hub design (`hub/clinical.js`), not changed here.

## Parity and contract tests (shared fixtures)

| Fixture (`docs/fixtures/`) | Generated from | Locked by |
| --- | --- | --- |
| `triage-parity-v1.json` (108 combinations) | `hub/risk.js` | `hub/triage-parity.test.js`, `TriageParityTests` |
| `observation-parity-v1.json` (39 cases) | `hub/ai.js` validator | `hub/observation-parity.test.js`, `ObservationParityTests` |
| `intake-parity-v1.json` (~70 transcripts) | `hub/rag/knowledge.js`, `hub/intake.js` | `hub/intake-parity.test.js`, `IntakeParityTests` |
| `native-processing-v1.json` | Swift app code | `HubContractTests` and `hub/native-contract.test.js` (the hub's real validator and intake) |

Change a rule in one language and the other side's test fails until it is mirrored. The bundled pack
`Sources/VanguardApple/Resources/medical_terms.json` must equal `hub/rag/medical_terms.json` (a test checks).
Regenerate fixtures with `WRITE_FIXTURE=1` (hub) or `VANGUARD_WRITE_FIXTURE=1` (Swift), then review the diff.

Defects found by these tests and by the real end-to-end run, all fixed: the Swift validator's quote-only
confirmation; the hub ETA picking "30 minutes ago" over "arriving in 10 minutes"; Tagalog filler words
("siyang", "yung") defeating phrase matching; and Swift omitting `"value": null`, which the real hub rejected.

## Running the checks

```sh
cd hub && DB_PATH=:memory: LIVE_AI=0 node --test
cd watch/apple && swift test                                   # needs .native/llama.xcframework
xcodebuild -scheme VanguardWatch -sdk watchos27.0 -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme VanguardPhone -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
# real model + real hub on this Mac (a scratch hub on 127.0.0.1:3010 with a throwaway database):
VANGUARD_LIVE_MODEL_DIR=models/qwen3-0.6b VANGUARD_TEST_HUB_URL=http://127.0.0.1:3010 swift test --filter "Live"
# regenerate the macOS renders of the ten screens:
VANGUARD_SCREENSHOT_DIR=docs/qa/apple-watch-voice-workflow swift test --filter WatchScreenshotTests
```

`swift test` and Watch builds need both native libraries. Run
`PLATFORMS="macos iphoneos iphonesimulator watchos" bash scripts/qwen-native-build.sh`
and `./scripts/whisper-watch-build.sh` (CMake required). The Whisper build creates
CPU-only Watch device and simulator slices from the pinned vendored source. Its
bundled multilingual model is 31 MB; retrieve it with
`git lfs pull --include='models/whisper-tiny-q5_1/*.bin'`. No physical Watch has
been tested.

## Evidence matrix (PASS / FAIL / BLOCKED)

| Requirement | Result | Evidence and limit |
| --- | --- | --- |
| UI fidelity, ten screens | **BLOCKED** (partly verified) | Real screen code rendered on macOS at Watch point size and compared with the storyboard (`docs/qa/apple-watch-voice-workflow/`). Colors sampled from the storyboard. No watchOS simulator runtime is installed, so the actual watchOS render, Digital Crown scrolling, Dynamic Type sizes and VoiceOver were not run. Screens 6 and 7 scroll slightly on a 41 mm display. |
| Recording captures real microphone input | **BLOCKED** | `MicrophoneRecorder` compiles for iOS and the watchOS device SDK. Controller behavior is tested with a fake microphone. A real-microphone test exists (`MicrophoneRecorderTests`) but the simulator test host cannot be granted microphone permission non-interactively, so it skipped. |
| Waveform responds to microphone input | **PASS** (logic) / **BLOCKED** (hardware) | Levels come only from the recorder interface, normalized by `AudioLevel`, and tests assert only reported values are shown. Not observed with real audio. |
| Audio persists safely | **PASS** (store/files) / **BLOCKED** (crash recovery) | Capture and file exist before the first sample; silence and interruption keep the file. CAF stays readable after a crash in theory; not tested. |
| Offline speech recognition | **Implemented / hardware blocked** | Watch uses bundled multilingual `whisper.cpp` tiny q5_1; iPhone still uses on-device Speech (`en-US`, `fil-PH`). Synthetic path tests and Watch SDK build do not prove physical Watch accuracy, memory or latency. |
| iPhone fallback | **PASS** (logic) / **BLOCKED** (transfer) | Pending-then-recovered flow and retained audio tested with stubs. `WatchRelay` compiles for both platforms; paired WatchConnectivity transfer was not run. |
| Qwen local inference | **PASS** on this Mac's CPU / **BLOCKED** on Watch and iPhone | Real Qwen3-0.6B (llama.cpp CPU, verified weights) ran 7 synthetic reports at about 2 s each. Memory, latency and thermals on Watch hardware are unknown. |
| Deterministic triage | **PASS** | Swift port matches the hub for all 108 combinations; unknown never becomes Minor. |
| Transcript immutable, corrections with provenance | **PASS** | Database triggers, versions, re-extraction and the hub revision verified. |
| Report persists across restart | **PASS** | Store reopen and upgrade-from-v1 tests; hub restart on the same database kept the delivered report. |
| Delivery to the existing hub | **PASS** (macOS, loopback) | Real delivery code to a real running hub; read back with correct location, count, age group and ETA. |
| Acknowledgment required for success | **PASS** | Invalid receipt is never delivered; the database refuses `DELIVERED` without a receipt. |
| Hospital dashboard shows delivered data | **PASS** (macOS) | The delivered report appeared on the real dashboard. |
| Backend restart / container replacement | **PASS** (restart) / **BLOCKED** (container) | Hub restart verified. Docker is not installed here. |
| Offline operation | **PASS** (processing) / **BLOCKED** (recording) | Extraction, triage and storage use no network. Recording was not exercised on hardware. |
| Retry without duplicates | **PASS** | Same report ID on every retry; replayed receipts count once; sent corrections are not resent. |
| Recent reports from real storage | **PASS** | List is read from SQLite rows. |
| Tests and builds | **PASS** | See the numbers below. |

Last run: hub 122 tests (121 pass, 1 skipped: live Ollama); Swift on macOS 81 tests (78 pass, 3 skipped: the three live
tests that need the model and a hub); Swift on the iOS 27 simulator 78 tests, 0 failures (run before the gated
microphone test was added, which skipped when run alone); watchOS device-SDK build (unsigned) and iPhone simulator
build succeeded; both live tests (real model, real hub) passed.

## Mac development host

`swift run VanguardWatchMac --model ../../models/qwen3-0.6b --hub http://127.0.0.1:3010` (from `watch/apple`) opens
the real Watch screens and pipeline in a Mac window with a 41/45/49 mm bezel. It is a test bench, not a product, and
says nothing about Apple Watch hardware: speech is the Mac's on-device recognizer, and the hub sees `MAC-DEV-HOST-` IDs.
`--fresh` uses a throwaway store and never delivers unless `--hub` is given. `--submit "text" --route triage --size 41
--snapshot out.png` photographs the real window (no screen-recording permission needed), which is how fit was checked.
Photographing the host found and fixed: missing title bar and corner insets outside watchOS, pushed screens that did
not refresh when data changed (they now observe the controller), recovery re-processing the capture being recorded,
and duplicate concurrent extractions of one capture (now one shared job per capture).

## Known limitations

* Not tested on any physical Apple Watch or iPhone: microphone, speech, WatchConnectivity transfer, on-device Qwen
  memory/latency/thermals, background behavior, battery. Do not promise continuous connectivity or background delivery.
* Qwen supplies only four observations and often leaves them unknown: in the example "Nahihirapan siyang huminga",
  breathing stays unknown because the confirmation phrase list has no filler tolerance. Loosening it is a clinical-rule
  decision. Symptom terms are shown from the pack regardless.
* Term pack and board setups are unreviewed drafts. Exact-phrase matching misses misspellings and unlisted wordings.
* Taglish inside one sentence can be transcribed imperfectly by a single-language recognizer.
* Legacy optional location, patient count, age group and ETA edits stay local: the hub exposes revisions only for
  transcript corrections, overrides and extractions.
* Corrections use scoped `GET /api/triage/source/:reportId`; a newer hospital revision leaves an older device correction pending for human reconciliation.
* Foreground retries run every 30 seconds; optional Hospital connection settings configure the LAN URL and Keychain token.
* Hub transport is unauthenticated HTTP on the LAN unless an access token is configured; storage is unencrypted.

## Current acceptance boundary

The 2026-10-10 delivery/observation/dashboard update used static analysis and unsigned
generic device builds only. Historical PASS rows above refer to earlier code.
See [manual checklist](triage-delivery-update.md). No unit, integration, E2E, simulator,
hardware, API smoke or automated transmission tests were executed for this update.
