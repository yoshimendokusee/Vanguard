# Implementation report — 2026-10-09

Branch: `codex/watch-offline-reporting`. The initial checkout was clean at
`a18bdcd`. A final fetch found three new UI commits; the branch was safely
fast-forwarded to `origin/main` at `931ccdc` and the implementation reapplied.
Conflicts were resolved to preserve the newer teal dashboard, accessibility,
search/filters, charts/readiness controls and watch light/dark theme. The recovered
implementation stash remains available as a safety copy. No feature commit, push,
remote PR, merge to main, deployment or repository-setting change was performed.

## Implemented features

- Existing Wear OS reports automatically attempt delivery **after SQLite save**,
  at startup/resume and during foreground retries. The optional action is now
  Retry Now. In-flight sync is shared; batches are limited to 100 reports and
  900 KiB; failure backoff is 60/120/240/480 seconds, returning to a 30-second
  interval on success. Background/suspended execution is not guaranteed.
- ACK validation rejects malformed responses, unsent IDs and contradictory
  accepted/rejected IDs. Only explicitly acknowledged transmitted rows are
  marked synced. Rejections, outages and dropped responses retain the queue.
- The hospital acknowledges identical replays but rejects conflicting immutable
  originals under the existing Watch/timestamp identity. Original legacy text is
  preserved exactly. Over-limit originals remain locally queued; other shorter
  reports can proceed. Unsupported `processing` is refused without ACK so its
  metadata cannot be silently lost before database integration.
- Hospital deterministic provisional rules rank exact structured findings, retain
  a higher source urgency and show rule reasons/version. Unknowns and unconfirmed
  death remain Unassessed. The dashboard's priority card, lists, category counts,
  filters, alerts and chart use effective priority; original category/note remain
  available in the selected report. Existing status updates remain supported.
- Native `watch/apple` Swift library: iPhone on-device-only speech transcription
  with permission/support checks, cancellation, empty-result handling and a
  55-second deadline; an actor serializes fallback recovery, keeps failed jobs
  pending and commits through the teammate's durable repository port. These are
  library modules, **not complete Apple applications or paired transfer**.
- Tested extraction metadata and structured risk utilities are ready for teammate
  integration. They do not execute Qwen or persist an extended report yet.
- Isolated Docker QA service, synthetic HTTP/priority/duplicate/persistence checker,
  Windows PowerShell workflow, and separate Qwen/database agent handoff documents.

## Scope and requirement status

The user explicitly reassigned Qwen and database implementation to teammates.
All migration/schema work from this agent was removed. No existing database,
database source/schema, data directory or queue was reset or overwritten.

| Approved requirement | Current delivery |
| --- | --- |
| Watch-primary offline STT | Blocked: watchOS SDK has no Speech.framework; no separately proven Watch STT runtime/app exists |
| Watch/iPhone Qwen | Teammate-owned; no runtime/artifact or inference evidence delivered here |
| Automatic phone fallback | On-device STT and recovery library implemented; full app, durable intake, Qwen and WatchConnectivity integration remain blocked |
| Browser Qwen | Teammate-owned; implementation and offline execution tests specified in handoff |
| Automatic reports/transmission | Implemented for the existing Wear OS capture/parser/SQLite path; Apple end-to-end pipeline awaits integration |
| Originals/corrections/provenance/uncertainty | Exact legacy originals preserved; extended processing contract validated; durable metadata/corrections/overrides await database owner |
| SQLite before transmission | Existing watch/hub ordering retained; new schema/native storage delegated |
| Automatic provisional hospital risk | Implemented, deterministic and transparent, with qualified verification required |
| Priority and clinician override | Priority implemented; durable clinical correction/override blocked on audited storage/API |
| Preserve existing implementations | Express, SQLite, Docker, Wear OS paths/frameworks and newer UI preserved |

## Architecture and dependencies

The modular monolith/three-tier separation and existing application locations remain.
Hospital risk and processing validation are feature modules inside `hub/`. The native
library sits inside `watch/apple`, with explicit application/data ports rather than a
new server. `hub/compose.qa.yaml` uses the same hospital application with isolated
synthetic storage. Root and legacy Compose files and their `hub/data` path are unchanged.

**Dependencies added: none.** No npm/Flutter dependency or lockfile change; native
code uses system Speech/Foundation and Swift concurrency. No model is bundled.
Model revisions/runtime versions/artifact checksums must be pinned by the Qwen owner
before claiming execution. Apple system speech assets are OS-managed; their weights
are not provided as pinned/checksummed artifacts by this implementation.

## Checks executed now

All fixtures are synthetic. Native state tests use an explicitly labeled processor
fixture; its output is not STT or Qwen execution evidence.

| Command/check | Result | Scope |
| --- | --- | --- |
| `cd hub && npm ci` | PASS | Locked dependencies installed; no dependency changes |
| `cd hub && npm test` | PASS, 17 tests | Legacy HTTP/dashboard/status/SSE, persistence reopen, rule/metadata validation, conflict/rollback/original preservation, priority selection |
| `cd watch && flutter pub get --enforce-lockfile` | PASS | Existing lockfile respected |
| `flutter analyze --no-pub` | PASS | No issues on current watch code |
| `flutter test --no-pub` | PASS, 18 tests | 12 parser tests; 6 batching/ACK/rejection/outage/concurrency/automatic-retry tests |
| `dart format` on edited Dart files | PASS | Watch code/tests formatted |
| `cd watch/apple && xcrun swift test` | PASS, 2 XCTest cases | macOS host recovery/cancellation state tests only |
| Xcode iOS Simulator library build | PASS | Generic simulator compile, not transcription execution |
| Xcode watchOS Simulator library build | PASS | Watch shared recovery code compile; STT excluded on watchOS |
| Xcode iPhone Simulator tests | PASS, 2 XCTest cases | iPhone 17, iOS 26.5; pending-capture commit recovery/cancellation |
| Xcode Watch Simulator tests | PASS, 2 XCTest cases | Apple Watch Series 11 (46mm), watchOS 26.5; same independent state tests |
| Root, legacy and QA `docker compose ... config --quiet` | PASS | All three service configurations parse |
| `docker build -t vanguard-hospital-qa hub` | PASS | Existing Dockerfile, no framework/container replacement |
| In-image `npm test`, `--network none`, `DB_PATH=:memory:` | PASS, 17 tests | Linux arm64 container on this Mac; loopback HTTP tests, synthetic/in-memory/temporary storage |
| `node qa/check.cjs`, repeat and `--expect-existing` after restart/recreation | PASS | Synthetic receipt, priority, duplicates/conflicts and four persistent pre-existing QA rows |
| Safari dashboard inspection | PASS | Synthetic hospital board displays provisional priority, source category, original note and rule reason; no browser Qwen claim |
| Repository validator and its Node tests | PASS, 6 tests | Configuration, migration guard and existing CI gate; no hosted CI claim |
| `git diff --check` | PASS | No patch whitespace/conflict-marker issue |

Native commands, from `watch/apple` (build/test output stored under `/tmp`):

```sh
xcrun swift test
xcodebuild -scheme VanguardApple -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme VanguardApple -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme VanguardApple -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
xcodebuild -scheme VanguardApple -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' CODE_SIGNING_ALLOWED=NO test
```

Observed toolchain: Xcode 27.0 (`27A266a`), SDKs iOS/watchOS 27.0,
Apple Swift 6.4 via `xcrun` (the shell's unrelated Swift 4.2 is not used), Flutter
3.47.5, Docker Desktop 4.94.0/Engine 29.8.2. The pinned existing Node/Flutter
dependencies/CI settings remain unchanged. Xcode emitted an App Intents metadata
warning for a package without AppIntents; build/test succeeded.

Earlier failures were corrected: Dart constructor lint and a test completer's
premature synthetic error; hospital priority/ETA ordering initially failed and
was corrected; QA port 3001 was occupied, so the isolated workflow now uses 3301.
The in-app browser blocked localhost and Chrome was unavailable; Safari supplied
the browser inspection. No other service was stopped or modified. A Safari AX
button attempt lacked a frame; status behavior is covered by HTTP tests, not
claimed as browser action validation.

## Unrun and blocked validation

- **Physical Watch/iPhone: unrun.** No connected device of either required type
  was available. A connected iPad does not substitute for this evidence. No signing
  or install on physical devices was attempted.
- **STT execution: unrun.** Native library compilation/state tests do not prove
  recognition, language coverage, provisioned offline speech assets, audio capture
  quality or accuracy. Run with microphone/speech privacy descriptions in actual
  native app targets, provision locales, and test with networking disabled.
- **Qwen execution: unrun/delegated** on every platform. Downloads/builds/state
  fixtures do not establish local model execution. Watch memory/latency/battery and
  runtime feasibility remain mandatory gates.
- **Full paired fallback: blocked** on actual native applications, retained capture
  intake, WatchConnectivity delivery/receipt handling, repository adapter and Qwen.
  Existing library recovery must be wired to durable receipt/resume/retry events.
- **Windows host/PowerShell: unrun.** This host is macOS and no PowerShell runtime
  is installed. Windows instructions are supplied; tested Linux-container behavior
  is recorded separately. Browser WebGPU/WASM inference remains delegated.
- **Disconnected-WAN browser reload: unrun.** Offline backend tests used Docker
  `--network none`; no user network was disabled. Dashboard has local assets, but
  that is not a browser offline-inference claim.
- **Hosted CI/PR review: unrun.** Local checks do not claim a remote workflow or
  physical device check passed. No PR was published.

## Files changed

- Hospital: `hub/server.js`, `hub/sync.js`, `hub/risk.js`, `hub/processing.js`,
  `hub/public/index.html`, `hub/sync.test.js`, `hub/contract.test.js`, `hub/risk.test.js`.
- Existing watch: `watch/lib/main.dart`, `watch/lib/services/sync_service.dart`,
  `watch/test/sync_service_test.dart`. Upstream `theme.dart` is retained unchanged.
- Native library: `watch/apple/Package.swift`,
  `Sources/VanguardApple/OnDeviceTranscriber.swift`, `FallbackProcessor.swift`,
  `Tests/VanguardAppleTests/FallbackProcessorTests.swift` (paths under `watch/apple`).
- QA: `hub/compose.qa.yaml`, `hub/qa/check.cjs`, `qa/windows-hospital.ps1`.
- Documentation: `README.md`, `docs/architecture.md`, `docs/api-contract.md`,
  `docs/qwen-agent-handoff.md`, `docs/database-team-handoff.md`,
  `docs/windows-qa.md`, this report.
- Housekeeping: `.gitignore`, `.github/scripts/validate-repository.test.js`
  (exclude generated Swift output from its synthetic repository copies).

Database sources, migrations, normal Compose files, package manifests/lockfiles,
existing persistent data and upstream UI/theme files outside these changes remain
untouched by this implementation.

## Windows QA and hackathon readiness

Run `./qa/windows-hospital.ps1` on Windows with Docker Desktop. It validates both
normal entry points, runs tests without network/persistent mounts, starts isolated
synthetic QA, submits reports, checks priority/duplicates/conflicts, verifies
SQLite after restart and records results. See `windows-qa.md` for manual browser,
offline and Qwen checks. No macOS is required for hospital/backend QA.

**Ready for a synthetic hospital/demo workflow; not ready for the complete
Watch-primary offline-AI hackathon claim.** Blocking deliverables are native apps,
Watch-local STT, actual local Qwen on all targets, database metadata/audit integration,
paired automatic recovery/delivery and independent physical/Windows validation.
The existing Vosk speech model is also absent, so a Wear OS microphone demo needs
provisioning and target hardware verification.

Current HTTP/SQLite remain unauthenticated/unencrypted. Scoped ACKs are a protocol
integrity improvement, not trusted hospital receipts. Use synthetic data in isolated
development only; qualified clinicians must verify provisional risk. Do not expose
the service publicly or use real patient data. Legacy short Watch IDs and restart/
clock-rollback timestamp collisions remain for the storage/platform team to fix.
