# Vanguard repository audit and foundation

> Backend update, 2026-10-09: `backend-completion.md` supersedes the database and
> structured-processing gaps below for the current working tree. It records the
> new workflows, performed checks and remaining clinical/platform limitations.
> Earlier dated observations below are historical evidence.

Date: 2026-10-09, Asia/Manila. Repository: `/Users/baronjoya/Vanguard`.
Baseline: `6ef35c4` (`Initial commit: Vanguard-Wrist offline medical triage MVP`).
Initial state: clean `main`, tracking `origin/main`. Work is uncommitted on
`docs/repository-foundation`. The separate `Vanguard copy` directory was not used.

This is a historical baseline audit, not a description of the current migration
state. Subsequent database work added the watch SQLite v1-to-v2 upgrade, the
transactional hub migration runner and baseline, and the Supabase report/RLS
migration. The Supabase migration has been applied to the configured project.

## Result

The existing implementation is a Flutter Wear OS-oriented Android app plus a
Node/Express/SQLite hospital hub serving a plain HTML dashboard. It is already
a small monorepo and has a local-first LAN report path. At audit time, the
approved target was broader than the implementation: mobile BLE relay, Supabase,
local LLM extraction, React/TypeScript/Tailwind and authenticated delivery were
not yet implemented.

The foundation preserved all application code, tests, schema definitions, watch
dependencies and paths. At audit time, no database had been reset or migration
applied, and no commit, push, PR or remote setting change was made. Checks used
in-memory databases or disposable temporary databases; `hub/data` still contains
only its original `.gitkeep`. Dependency installation generated ignored local
build/cache files. Docker checks created local images/build cache; temporary test
containers and the dedicated test project's network were removed.

## Actual application and dependencies

| Area | Evidence | Implemented behavior |
| --- | --- | --- |
| Watch presentation | `watch/lib/main.dart`, Android manifest | High-contrast dictation/stop control, transcript, pending count, saved report, haptics, manual send and header demo phrase. Wear OS standalone declaration, mic/internet/vibration permissions; cleartext HTTP allowed. |
| Offline speech | `watch/lib/services/speech_service.dart`, `watch/assets/models/.gitkeep` | Vosk asset loader, 16 kHz recognizer, partial/final transcript streams. Model ZIP absent. Normal recording and demo header flow require successful speech initialization. |
| Triage extraction | `watch/lib/nlp/triage_parser.dart`, 12 parser tests | Deterministic Taglish keywords/fuzzy matching; findings, count, age, four mapped pickup locations, ETA and provisional category. Unrecognized nonempty speech remains Unassessed. |
| Watch persistence | `watch/lib/db/triage_db.dart` | sqflite schema version 2 with an in-place v1 upgrade adding stable report UUIDs and separate cloud-sync ownership/state while preserving LAN queue state. Persistence on native hardware has not been run. |
| LAN sender | `watch/lib/services/sync_service.dart:35–74` | Sends all pending rows, eight-second timeout; sets returned IDs synced. No batching, automatic retry scheduler, cloud or BLE. |
| Hub application | `hub/server.js`, `hub/sync.js` | Express JSON routes, input caps/validation, transactional ingest, duplicate ACKs, status updates, SSE and static files. API exposes health/config/list/sync/status/events. |
| Hub persistence | `hub/db.js`, `hub/migrations/0001_initial_schema.sql` | better-sqlite3, WAL, numbered transactional migrations using `PRAGMA user_version`; compatible legacy databases are adopted without dropping reports. |
| Hospital dashboard | `hub/public/index.html` | Surge totals, provisional acuity/ETA ordering, preparation hints, Arrived/Cancel/Reopen controls, SSE + polling, no CDN. Uses `textContent` for untrusted transcripts. |
| Docker/demo | `hub/Dockerfile`, `hub/docker-compose.yml`, `fake-watch.sh` | One container for API + dashboard; `hub/data` bind mount; synthetic curl sender. No separate dashboard or AI service. |

Hub manifests contain only Express `^4.21.0` and better-sqlite3 `^13.0.3`, with
Node's built-in test runner. The lockfile fixes better-sqlite3 at 13.0.3; dependency
versions were not upgraded. The Node engine declaration was corrected from >=20
to >=22 to match that locked native dependency. Current watch dependencies include
Flutter, cupertino_icons, vosk_flutter, sqflite, path, supabase_flutter, uuid,
vibration, http and permission_handler; dev dependencies include flutter_test,
sqflite_common_ffi and flutter_lints. No BLE, React, TypeScript, Tailwind or LLM
dependency exists.

Local tooling: Node 24.20.0, npm 11.19.0, Flutter 3.47.5 / Dart 3.13.4,
Docker Compose 5.5.1 and Docker Engine 29.8.2 on arm64. Container checks used
Node 22.23.3. `flutter doctor -v` found no Android SDK and no attached Wear OS/
Android test device; no native watch build or install was attempted.

## Gap analysis and work order

| Priority | Gap and evidence | Required next work |
| --- | --- | --- |
| First | Model folder is empty; `_boot` waits for Vosk init (`main.dart:77–98`). | Provision a suitable model and Android SDK; measure offline STT accuracy, load time, RAM, battery, mic permissions and haptics on a real watch. Test unknown speech and process restart. The [Vosk catalogue](https://alphacephei.com/vosk/models) lists default English at 40M and Filipino at 320M; asset selection is not proof of Taglish accuracy. |
| First | Unauthenticated plain HTTP routes (`server.js`); unencrypted SQLite; arbitrary `raw_text`. | Keep synthetic isolated demos until authenticated access, protected transport/storage and retention are implemented. Transcripts can contain identifying information even without a name field. No secure-delivery claim is justified. |
| First | Four-hex-digit watch IDs (`triage_db.dart:84–87`); `_lastTs` resets per process (`:57,95–102`); unique timestamp key (`db.js`). | Add a durable globally unique report identity with backward-compatible migration/contract tests. Test ID collisions and restart/clock rollback; the current hub silently ignores differing content with the same identity. |
| First | Sender loads every pending row (`sync_service.dart:36–55`); server caps 500 reports/1 MB (`server.js:11,45–46`). | Add bounded batching, rejection visibility and durable retry semantics. Test >500 pending reports, large transcripts, interrupted sends and partial rejections without discarding rows. |
| First | ACK IDs are accepted directly (`sync_service.dart:68–70`); `markSynced` updates any returned IDs (`triage_db.dart:139–144`). | Authenticate the receiver, validate response structure/counts and scope IDs to the sent batch before changing delivery state. Distinguish persisted LAN receipt, relay receipt, cloud upload and trusted hospital delivery. |
| Next | Capture auto-saves then shows a card (`main.dart:135–149`); no local LLM or explicit review flow. | Implement measured on-device extraction only if needed, preserve uncertainty, and add user/qualified-person review with deterministic provisional triage. Parser tests are not clinical validation; negation/mixed-group limits remain. |
| Resolved | At audit time, there was no executable hub migration runner. | Hub now applies the baseline transactionally and tests fresh creation, compatible legacy adoption, incompatible schema rejection and rollback. |
| Next | No companion app, BLE permissions/dependency/protocol or relay queue. | Implement the smallest foreground Android relay first, then target iOS and Wear OS interoperability; test encrypted fragments, retries, dedupe, hops/expiry and hospital ACK return on actual devices. |
| Resolved | At audit time, there was no Supabase code/config/schema/RLS. | Auth-backed report sync and an RLS migration now exist; the migration has been applied to the configured project. Verify offline capture and hospital LAN operation independently of cloud access. |
| Later | Dashboard is plain HTML; backend is three small CommonJS modules. | Implement React/TypeScript/Tailwind as a tested replacement when needed; preserve the current board and LAN API. Add actual feature modules without splitting the monolith or moving all paths for appearance. |
| Team setup | No hosted CI execution or branch-protection inspection/change. | Push/open a PR when authorized; verify `Hub tests`, `Watch analysis and parser tests`, and `Compose and container tests` on GitHub, then have administrators require those checks/review. Add CODEOWNERS when actual reviewers are agreed. |

BLE background behavior must be measured per device, OS, foreground/background,
screen-lock, app termination, power-saving and permission state. iOS can change
background scanning/advertising behavior and suspend execution; Android also
imposes background execution constraints. No continuous cross-platform relay or
successful delivery is promised. Sources:
[Apple Core Bluetooth background behavior](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
and [Android background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background).

## Files changed

Added (16):

- `AGENTS.md`: architecture, offline data/ACK, security, migration and honest-test guardrails.
- `docs/architecture.md`: approved target, actual implementation and extension boundaries.
- `docs/api-contract.md`: implemented HTTP API, field validation, statuses, SSE and ACK limitations.
- `docs/conventions.md`: code, shared-contract, contribution and verification conventions.
- `docs/reverse-engineering.md`: this dated audit.
- `.editorconfig`, `.env.example`: formatting and current configuration only.
- `compose.yaml`: includes the original hub service without duplicating its data paths.
- `.github/PULL_REQUEST_TEMPLATE.md` and `.github/ISSUE_TEMPLATE/{bug,feature}.yml`.
- `.github/workflows/ci.yml`: least-privilege checks for existing applications; action revisions pinned, Flutter 3.47.5, Node 22.
- `database/migrations/README.md`, `database/migrations/{hub,watch}/.gitkeep` and `supabase/migrations/README.md`: schema ownership/layout, with unapplied/planned status explicit.

Modified (8):

- `README.md`, `docs/DEVELOPER_GUIDE.md`: reconciled setup/status, model provisioning, privacy, process-local timestamps and historical verification claims.
- `.gitignore`, `hub/.dockerignore`: local configuration, model/data artifacts and key exclusions; `.env.example`, lockfiles and placeholders retained.
- `hub/docker-compose.yml`: configurable hospital label and host binding/port; existing defaults and `hub/data` retained. The example config chooses loopback for local development.
- `hub/Dockerfile`: locked install and native-addon build stage; compiler/Python absent from final runtime.
- `hub/package.json`, `hub/package-lock.json`: Node >=22 metadata only; package versions unchanged.

No CODEOWNERS identities were invented. No empty application/module stacks or
optional AI/simulator containers were added.

## Verification performed

| Check actually run | Result and scope |
| --- | --- |
| Native hub `npm ci`; `npm test` | Passed, 7/7 before and after foundation changes. Tests use in-memory SQLite and real loopback HTTP. |
| `flutter pub get --enforce-lockfile` | Passed; watch lockfile unchanged. |
| `flutter analyze`; `flutter test` | Clean analysis; 12/12 parser tests passed. No watch code/dependencies changed afterwards. |
| Root and legacy `docker compose ... config --quiet` | Passed. Assertions verified both resolve build context to `hub/`, mount the same `hub/data`, and preserve unconfigured all-interface port 3000 binding. |
| Root `--env-file .env.example config` | Passed; assertions confirmed loopback binding, host port and hospital configuration. No `.env` or credentials created. |
| Locked root Compose build | Passed after correcting missing native compiler tools. Initial `npm ci` build failed because the slim image lacked Python; build stage now installs Python/make/g++. No dependency upgrade used as a workaround. |
| Final image `npm test`, `--network none` | Passed, 7/7 on Linux arm64 without external networking. Tests still use loopback inside the container. |
| CI's Compose one-off test command, in-memory DB | Passed, 7/7. No service was started against a persistent report database. |
| Disposable hub self-check, native and final image without external networking | Passed health/config, static HTML serving + inline script syntax, bad-envelope 400, >500-report 413, SSE notification, disk close/reopen retention and duplicate behavior. Uses synthetic data and removes its temp database. This is not browser-rendering or watch SQLite evidence. |
| JavaScript syntax, `bash -n fake-watch.sh`, `git diff --check` | Passed. |
| Workflow `actionlint`, YAML/issue-form parsing | Passed locally. Hosted GitHub Actions not run. |
| Ignore/compatibility assertions | Passed: secrets/data/models ignored; example config, lockfiles and `.gitkeep` not ignored; application code, native config, schemas and existing tests unchanged. Runtime image has no g++ or Python. |

Not run: native APK/release build, watch Vosk/sqflite/haptics/microphone/round-screen
accessibility, watch restart/recovery or broken-Wi-Fi sync, browser rendering/user
interaction, clinical validation, Android/iOS BLE, cloud sync/RLS, real hospital LAN
device traffic and hosted CI. No software test establishes BLE background reliability.
The container build/test evidence covers Linux arm64, not a separately tested amd64 image.

Immediate next step: provision the speech asset and Android SDK, validate the
existing offline capture/restart/LAN flow on a real watch, then address durable
identity, bounded sync and authenticated/scoped acknowledgments before broadening
transport or patient-data use. The approved extension roadmap is preserved in
`architecture.md`; this foundation does not implement those product extensions.
