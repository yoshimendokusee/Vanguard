# Five-observation implementation and verification

Date: 2026-10-10. All patient information used in verification was synthetic. Results below are checks run for this change, not inherited claims.

## Branch and workspace

Final review branch: `feature/global-five-observation-triage-20261010`.

Review checkout: `/Users/baronjoya/.codex/worktrees/five-observation-triage/Vanguard`.

The requested `feature/global-five-observation-triage` was created before editing, from `28d0043`. Another process subsequently switched and committed unrelated work in the shared checkout. The implementation was moved to an attached isolated worktree based on the resulting `2cd451f`, on the unique branch above. Only byte-identical copies of this task's changes were removed from the shared checkout after checking the branch, patch and file contents. Other changes were preserved. At implementation verification time, no commits, pushes, merges, deployment, remote changes or patient-database resets had been performed. The subsequent user request to create a PR authorizes committing and publishing this feature branch; it does not authorize merging or deployment.

## Implemented behavior

The existing processing-v1 JSON envelope now represents five observations. Existing machine state names are retained; the compatible additions are confused responsiveness, uncertain bleeding, assisted walking and reported radial pulse:

| Field | Supported machine states |
| --- | --- |
| `breathing` | `normal`, `abnormal`, `absent`, `unknown` |
| `consciousness` | `alert`, `confused`, `unresponsive`, `unknown` |
| `severeBleeding` | `present`, `absent`, `uncertain`, `unknown` |
| `walking` | `able`, `unable`, `assisted`, `unknown` |
| `circulation` | `present`, `absent`, `uncertain`, `unknown` |

Historical four-field results read with unknown circulation. Their immutable persisted originals and revision snapshots are preserved. Invalid explicit circulation values are rejected. Existing JSON columns store new five-field results; no database schema migration or applied-migration rewrite was needed.

Watch and iPhone reuse the same Qwen3-0.6B runtime, five-field prompt, native validation and display helper. Both show five statuses and the short optional voice guide. Unknown fields do not prevent the existing submission workflow. Qwen suggestions are checked against the current transcript; explicit supported evidence can recover a finding omitted by the model. The bounded language pack is identical on the hub and Apple targets. It covers English, Filipino and Taglish, negation, uncertainty/questions, conflicting statements, explicit corrections, historical statements, obvious other subjects and multiple-patient references. Unsupported wording remains unknown. Awake, a bare mention of breathing, a drowning event, a pulse rate or the rescuer's watch measurements do not establish a normal observation or palpable patient radial pulse.

Fallback receipt persists the source capture, encounter identity and existing STT provenance in one SQLite transaction. A Watch with saved speech sends that exact text after inference failure; a Watch without speech keeps its recording and queues the existing audio transfer. Original Watch audio remains local. Returned findings are grounded again before Watch adoption. Pending captures survive model, transport and identity errors. Watch and phone retain the same report/encounter identity, and each sender requires its own scoped hospital LAN acknowledgement. Paired transfer receipt or queued work is not hospital delivery.

The hospital accepts, stores and returns the fifth field using its existing endpoints and SQLite store. Replay compares normalized historical results so a missing historical circulation value cannot create a false duplicate conflict. Corrections keep the original transcript, history and identities. The existing deterministic triage calculation is unchanged; circulation is stored and displayed without a new scoring rule. Hospital machine findings remain unverified and retain the existing provisional assessment policy.

The existing dashboard is JavaScript, not TypeScript. Its actual client validator and rendering were extended together. Expanded persisted report cards and extraction preview show the five statuses; safe DOM text rendering and unknown labels are retained. Original text, correction and history controls remain available. Missing optional pairing/cloud controls in the current dashboard caused startup errors; small null guards allow the current board to initialize while retaining those handlers when controls exist.

The existing offline glossary gained radial-pulse vocabulary. It contains terminology definitions, not patient examples. Optional synthetic-example RAG was not introduced; its 100-held-out, five-percentage-point improvement and critical-recall acceptance evaluation was not run. No model upgrade, LoRA, embedding model, cloud inference dependency, framework replacement or new package was added.

## Component status

A PASS is scoped to the specific execution evidence listed. Builds are not hardware or clinical-accuracy evidence.

| Component / path | Status | Evidence and limits |
| --- | --- | --- |
| Feature branch and isolated review checkout | PASS | Feature branch verified; commit/publication authorized by the subsequent PR request. |
| Shared observation model / serialization | PASS | Swift/hub contract tests, invalid-value tests and historical four-field round trips. |
| Watch native five-field workflow | PASS | Shared native workflow executed on macOS, persisted and queued all five values; Watch targets compile. |
| Physical Watch recording, offline STT and Qwen runtime | NOT TESTED | No physical Watch speech, memory, battery, latency or hardware execution check. |
| iPhone inference-only fallback | PASS | Real local Qwen on macOS with phone workflow, source identity transfer, Watch result adoption and both senders acknowledged as one hospital report. |
| Fallback recording/text preservation and errors | PASS | Synthetic retained file, saved-STT handoff, missing-model retry, repeated adoption and atomic rollback/reopen regression tests. |
| Paired WatchConnectivity audio transfer / iPhone STT | NOT TESTED | Source wired to existing offline paths and both targets build; no actual paired transfer or phone audio transcription exercised. |
| Qwen3-0.6B five-field extraction | PASS | Real llama.cpp CPU generation for six English/Filipino/Taglish/unknown/injection transcripts; exact five JSON keys and grounded expected observations asserted. |
| Grounding safety / multilingual regression | PASS | 67 manually specified synthetic cases, three claim variants each, exercised in Swift and JavaScript; additional existing parity fixtures. Bounded coverage, not general NLP validation. |
| Backend API / correction / acknowledgement | PASS | Real HTTP synthetic integration, retrieved backend data, revision preservation and scoped receipt checks. |
| SQLite persistence / legacy compatibility | PASS | Fresh and populated temporary stores, close/reopen, four-field read/replay, immutable bytes/history, atomic failed handoff and no duplicate ingestion. Existing migration tests included in hub suite. |
| Hospital dashboard | PASS | Automated real renderer checks, successful dashboard build, actual browser card expansion using a Qwen-ingested report, historical unknown circulation and live correction refresh. |
| No connectivity → retry → hospital receipt | PASS | Unavailable LAN retains extracted processing and RETRY_REQUIRED; restored local HTTP transport yields explicit receipt; repeated phone/Watch delivery yields one hospital report. |
| Deterministic triage preserved | PASS | Existing triage parity fixture exercised with every circulation state; existing rules retained. |
| Relevant native regression tests | PASS | Final selected run: 65 tests, 0 skipped, 0 failures, including real-Qwen and real-HTTP paths. |
| Complete Swift suite | FAIL | 93 tests; 5 opt-in tests skipped; 10 assertion failures in one existing intake-parity test. Same failures reproduced from untouched initial commit; described below. |
| Hub source and Docker-image suites | PASS | Each: 134 tests, 133 passed, 1 opt-in live-AI test skipped, 0 failures. |
| Simulator and unsigned Apple device builds | PASS | iOS simulator, watchOS simulator, iOS device SDK and watchOS device SDK builds. No signed installation or device execution. |
| Both Compose entry points / Docker build | PASS | Both configs validate; image builds and tests against in-memory SQLite. |
| Physical end-to-end Paths A/B/C | NOT TESTED | Native/HTTP paths are tested with typed synthetic input; physical microphone/STT/paired transfer/background conditions remain unverified. |
| Optional synthetic-example RAG evaluation | NOT TESTED | Optimization omitted; baseline extraction retained. |
| Hosted CI and legacy Flutter app | NOT TESTED | No hosted CI run; Flutter source untouched. |

## Commands and actual results

Commands use the review checkout unless noted. Temporary logs reside under `/tmp`; they are local execution evidence, not repository artifacts.

- `cd hub && npm ci`: PASS in the initial shared checkout, 86 packages installed and zero reported vulnerabilities. The isolated worktree reused those ignored dependencies.
- `cd hub && npm test`: PASS, 134 tests / 133 passed / 1 skipped / 0 failed. Final log: `/tmp/vanguard-five-final-hub.log`.
- `cd hub && npm run build`: PASS, Vite production dashboard build. Log: `/tmp/vanguard-five-worktree-dashboard.log`.
- `WRITE_FIXTURE=1 node --test hub/observation-parity.test.js`: PASS; refreshed shared expected parity values after conservative grounding changes. Log: `/tmp/vanguard-five-final-phrase-fixture.log`.
- `VANGUARD_WRITE_FIXTURE=1 xcrun swift test --filter HubContractTests` from `watch/apple`: PASS earlier in this task; generated five-field native processing contract fixture, subsequently checked by both languages.
- `xcrun swift test --skip-build` from `watch/apple`: FAIL, 93 tests / 5 skipped / 10 assertion failures in one intake-parity test. Log: `/tmp/vanguard-five-resume-full-swift.log`.
- `xcrun swift test --package-path /tmp/vanguard-five-baseline.ItmyBd/watch/apple --filter IntakeParityTests`: FAIL with the same 10 assertions on archived untouched `28d0043`. Log: `/tmp/vanguard-five-baseline.log`.
- Initial plain `swift test`: FAIL at the installed non-Xcode toolchain's package tools-version parsing; all subsequent native checks used `xcrun swift` successfully.
- `docker compose config --quiet`: PASS.
- `docker compose -f hub/docker-compose.yml config --quiet`: PASS.
- `docker build -t vanguard-five-observation-final ./hub`: PASS. Log: `/tmp/vanguard-five-docker-final-build.log`.
- `git diff --check`: PASS. No staged changes, model-weight changes or new dependencies.

Final selected native run:

```sh
cd watch/apple
VANGUARD_LIVE_MODEL_DIR=/Users/baronjoya/Vanguard/models/qwen3-0.6b \
VANGUARD_TEST_HUB_URL=http://127.0.0.1:3018 \
xcrun swift test --filter 'FiveObservationTests|LiveEndToEndTests|ObservationParityTests|HubContractTests|TriageParityTests|AiContractTests|DeliveryTests|FallbackProcessorTests|VoiceStoreTests|VoiceReportControllerTests|HubTests'
```

PASS: 65 tests, no skipped tests or failures. The filter also selects `LiveFiveObservationTests`. Log: `/tmp/vanguard-five-resume-final-native.log`. The local hub used a new synthetic temporary SQLite file, not an existing datastore. Local Qwen weights and bundled native runtimes were reused and verified against existing manifests; weight content did not change.

Final Docker test run:

```sh
docker run --rm -e DB_PATH=:memory: -e LIVE_AI=0 \
  -v /Users/baronjoya/.codex/worktrees/five-observation-triage/Vanguard/docs:/docs:ro \
  -v /Users/baronjoya/.codex/worktrees/five-observation-triage/Vanguard/watch/lib:/watch/lib:ro \
  -v /Users/baronjoya/.codex/worktrees/five-observation-triage/Vanguard/watch/apple/Sources/VanguardApple:/watch/apple/Sources/VanguardApple:ro \
  -v /Users/baronjoya/Vanguard/models:/models:ro \
  vanguard-five-observation-final node --test
```

PASS: 134 tests / 133 passed / 1 skipped / 0 failed. Log: `/tmp/vanguard-five-docker-final-tests.log`. The skipped hub live-AI test is separate from the real native Qwen tests, which ran successfully.

Final Apple builds, from the review root:

```sh
xcodebuild -project watch/apple/Vanguard.xcodeproj -scheme VanguardPhone \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/vanguard-five-ios-build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
xcodebuild -project watch/apple/Vanguard.xcodeproj -scheme VanguardPhone \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/vanguard-five-phone-device-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project watch/apple/Vanguard.xcodeproj -scheme VanguardWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/vanguard-five-watch-build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
xcodebuild -project watch/apple/Vanguard.xcodeproj -scheme VanguardWatch \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/vanguard-five-watch-device-build CODE_SIGNING_ALLOWED=NO build
```

PASS for all four. Logs: `/tmp/vanguard-five-resume-ios.log`, `/tmp/vanguard-five-resume-phone-device.log`, `/tmp/vanguard-five-resume-watch.log`, `/tmp/vanguard-five-resume-watch-device.log`. An initial isolated-build attempt failed because its model file was an LFS pointer; materializing the already verified local artifact resolved the build without changing model content.

Browser verification used a temporary localhost hospital on port 3017 and synthetic records. Expanded backend-backed cards displayed all five actual statuses. A legacy four-field record displayed explicit unknown circulation. A persisted correction from present to absent radial pulse refreshed the expanded row through the existing live update path. Original text and correction controls remained visible. The later final native integration used the isolated worktree hospital on port 3018.

## Remaining issues and physical limitations

The complete Swift suite is not green. `IntakeParityTests.testSwiftMatchesTheHubForEveryFixtureTranscript` has ten baseline assertions: missing symptom-duration evidence and one clitic matched-phrase mismatch. These reproduce on untouched `28d0043`; the intake implementation was not changed to hide the failure. This prevents a claim that every repository check passed, even though all selected feature regressions pass.

General clinical accuracy, unrestricted subject resolution and unlisted phrasing are not established by 67 synthetic grounding cases or six real-model examples. The validator is intentionally bounded; new phrasing needs reviewed fixtures in both implementations. Speech recognition errors can omit or alter evidence and remain a hardware/language verification risk.

Physical Watch recording/STT/Qwen performance, actual iPhone offline speech language availability, paired WatchConnectivity handoff/result receipt, radio interruptions and foreground/background/locked device states remain NOT TESTED. Compiled device SDK builds and macOS execution do not establish these behaviors. Therefore the implementation is ready for review with tested native/HTTP paths, but full physical-device acceptance remains outstanding.

The current prototype's LAN HTTP and SQLite security posture is unchanged and is not suitable for real patient deployment. No public/shared-network or real-patient test was performed.

## Implementation continuation — 2026-10-10

The resumed implementation found and fixed an audio-to-text fallback retry gap: a phone that had already persisted Watch audio rejected the Watch's later recovered transcript as a capture identity conflict. `NativeStore.saveFallback` now returns the stored capture while adding the recovered speech and provenance atomically. The relay processes that canonical capture. Audio, capture identity, encounter and earlier original speech remain unchanged. Late speech that conflicts with an already completed extraction is rejected before any new transcription is committed.

Two new regression tests reproduced the faults before their fixes. The retry regression failed with `identityConflict`; the completed-original regression showed conflicting late speech being saved. Both pass after the changes, including close/reopen and original recording retention. The real local Qwen/HTTP fallback test now starts with a synthetic retained recording, receives the later saved Watch transcript, processes on the phone workflow, adopts on the Watch workflow and verifies both senders are acknowledged with one persisted hospital report. It does not execute STT or physical WatchConnectivity.

Current continuation results:

- PASS: selected native command above, 65 tests / 0 skipped / 0 failures; `/tmp/vanguard-five-resume-final-native.log`.
- PASS: `cd hub && node --test native-contract.test.js five-observations.test.js`, 8 tests / 0 skipped / 0 failures; `/tmp/vanguard-five-resume-hub-contract.log`. Full hub and Docker suite results earlier in this report were not rerun for the native-only retry change.
- PASS: all four Apple build commands above, rerun after the final storage guard; corresponding `/tmp/vanguard-five-resume-*.log` files.
- FAIL: `cd watch/apple && xcrun swift test --skip-build`, 93 tests / 5 skipped / 10 assertions in the same baseline intake-parity test; `/tmp/vanguard-five-resume-full-swift.log`. The new fallback regressions pass.
- PASS: `git diff --check`.
- NOT TESTED: physical speech, paired transfer, locked/background behavior, hosted CI and optional synthetic RAG remain outstanding.

## PR preparation — 2026-10-10

The feature was committed and rebased onto current `origin/main` (`bd23120`) for the user-authorized PR. Only the feature commit was transplanted; the unrelated Docker pull-retry commit `2cd451f` is excluded. Dashboard conflicts retained main's existing optional control handlers plus this feature's five-field rendering.

Post-rebase checks: PASS for the full hub suite (134 tests, 133 passed, 1 opt-in skip), dashboard production build, six repository-policy self-tests, repository validation, whitespace and both Compose configurations. Logs: `/tmp/vanguard-five-pr-hub.log` and `/tmp/vanguard-five-pr-dashboard.log`. Apple source did not change in the rebase; the earlier 65 native test and four Apple build results remain the native evidence.

A fresh temporary SQLite-backed hospital on localhost:3020 and synthetic PR fixture were checked in the actual browser. The expanded card displayed Difficulty breathing, Unresponsive, Severe bleeding reported, Unable and Radial pulse palpable, with the existing unverified/Unassessed assessment. Screenshot export failed because the in-app browser screenshot API could not bind the native tab to its browser session; no screenshot was produced. This is stated in the PR rather than substituting an older screenshot.

Hosted CI and teammate review are pending when the PR is opened. Physical-device acceptance and the pre-existing Swift intake-parity failure remain as documented above.

## Files changed

- `docs/ai-contract.md`
- `docs/api-contract.md`
- `docs/apple-watch-voice-workflow.md`
- `docs/architecture.md`
- `docs/five-observation-implementation.md`
- `docs/fixtures/five-observations-v1.json`
- `docs/fixtures/intake-parity-v1.json`
- `docs/fixtures/native-processing-v1.json`
- `docs/fixtures/observation-parity-v1.json`
- `docs/qwen-agent-handoff.md`
- `docs/reverse-engineering.md`
- `hub/ai.js`
- `hub/ai.test.js`
- `hub/clinical.js`
- `hub/contract.test.js`
- `hub/five-observations.test.js`
- `hub/observation-confirmation.js`
- `hub/observation-phrases.json`
- `hub/processing.js`
- `hub/public/dashboard.js`
- `hub/public/hub-client.js`
- `hub/public/index.html`
- `hub/public/observations.js`
- `hub/rag/integration.test.js`
- `hub/rag/knowledge.test.js`
- `hub/rag/medical_terms.json`
- `hub/risk.js`
- `hub/sync.js`
- `watch/apple/App/VanguardApp.swift`
- `watch/apple/Package.swift`
- `watch/apple/Sources/VanguardApple/AiContract.swift`
- `watch/apple/Sources/VanguardApple/NativeClinical.swift`
- `watch/apple/Sources/VanguardApple/NativeStore+Voice.swift`
- `watch/apple/Sources/VanguardApple/NativeStore.swift`
- `watch/apple/Sources/VanguardApple/NativeWorkflow.swift`
- `watch/apple/Sources/VanguardApple/ObservationConfirmation.swift`
- `watch/apple/Sources/VanguardApple/ObservationPresentation.swift`
- `watch/apple/Sources/VanguardApple/Resources/medical_terms.json`
- `watch/apple/Sources/VanguardApple/Resources/observation-phrases.json`
- `watch/apple/Sources/VanguardApple/Triage.swift`
- `watch/apple/Sources/VanguardApple/VoiceRuntime.swift`
- `watch/apple/Sources/VanguardApple/WatchRelay.swift`
- `watch/apple/Sources/VanguardApple/WatchUI/WatchRootView.swift`
- `watch/apple/Sources/VanguardApple/WatchUI/WatchScreens.swift`
- `watch/apple/Tests/VanguardAppleTests/FiveObservationTests.swift`
- `watch/apple/Tests/VanguardAppleTests/LiveEndToEndTests.swift`
- `watch/apple/Tests/VanguardAppleTests/LiveFiveObservationTests.swift`
- `watch/apple/Tests/VanguardAppleTests/ObservationParityTests.swift`
- `watch/apple/Tests/VanguardAppleTests/VoiceReportControllerTests.swift`
- `watch/apple/Tests/VanguardAppleTests/VoiceStoreTests.swift`
