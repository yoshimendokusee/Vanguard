# Vanguard-Wrist architecture — source of truth

Original prototype reconciled with commit `6ef35c4`; platform scope and CI updated
on 2026-10-09. This document records both the
approved target and the implemented prototype. The target is not a claim of
completion. Keep application paths unchanged until an integration needs a move.

## Approved target

Offline-first modular monolith with distributed edge clients; three-tier
separation; feature-based modules; one monorepo; feature branches, PR review and
GitHub Actions. Product targets are Apple Watch, iPhone and the hospital web app;
Android is outside the requested implementation scope. Docker Compose supports
hospital/server development. Apple clients use native SDKs outside Docker; the
watch-first processing design remains subject to its implementation approval.
Preserve the existing Flutter/Wear OS prototype while adding real Apple targets.

| Area | Target | Actual code and gap |
| --- | --- | --- |
| Watch | Offline Apple Watch capture, transcription/extraction, persistence and automatic LAN reporting | `watch/`: legacy Flutter Android project; Vosk wrapper, deterministic Taglish parser, SQLite queue, haptics and automatic foreground LAN retry. Native SwiftUI watchOS target, local CPU Qwen and SQLite now exist in `watch/apple`; simulator generation passed. Physical inference and offline Watch STT remain unverified/unimplemented respectively. |
| Local AI | Offline STT + lightweight local LLM extraction + deterministic triage + human review | Vosk integration and keyword/fuzzy parser exist. Pinned repository GGUF, local Ollama and vendored CPU llama.cpp are integrated; machine claims stay unverified and deterministic rules remain authoritative; automatic reporting does not require pre-send review. |
| Mobile | Paired iPhone offline processing fallback | Native `watch/apple` library provides on-device iPhone STT and fallback recovery ports; native SwiftUI iPhone target, SQLite adapter, Qwen runtime and bounded Watch Connectivity job/result transfer now exist; physical speech/paired transfer are unverified. Build-time `HUB_URL` (and optional publishable-only Supabase values) flow from `watch/apple/Config/*.xcconfig` through `Config/Info.plist` to `AppConfiguration`; an in-app hub URL overrides it. Not compiled in this Windows workspace. Legacy Android code does not establish iPhone support. |
| Offline relay | Authenticated/encrypted BLE store-and-forward | No BLE dependency, permissions, protocol, durable relay queue, fragmentation, hop/expiry controls or return acknowledgment path. |
| Local data | SQLite first on clients and hospital | Watch `triage_logs` + `meta` with sqflite v1→v2 upgrade; hub `triage_reports` with WAL and numbered transactional migrations. Hub v2 stores patient/encounter revisions, original processing and assessment/receipt history. Neither database is encrypted; no retention policy. |
| Hospital LAN | Offline receiving API + dashboard | Express, SQLite, local HTML/CSS/JS, SSE + polling and deterministic provisional priority. Structured evidence, encounter links, immutable corrections and provisional overrides are persisted through hub v2. HTTP without auth/TLS. |
| Backend | Node/Express modular monolith | One service: `server.js` HTTP, `sync.js` ingest, `db.js` migrations, `processing.js`/`risk.js` validation and rules, `clinical.js` report history and `records.js` patient/encounter workflows. Do not split into services. Add feature modules as features arrive. |
| Dashboard | React + TypeScript + Tailwind | Current dashboard is `hub/public/index.html`, with no React/TypeScript/Tailwind dependencies. Docker development now adds Vite for its vanilla CSS/JavaScript; production assets are built and served by Express. Retain it until a separately tested replacement exists. |
| Cloud | Supabase PostgreSQL/Auth/Realtime + idempotent sync | Watch has authenticated, owner-scoped upsert sync to `triage_reports` with RLS and a versioned SQL migration. The hub (`hub/cloud.js`) backs up received source reports to the same table as its own Supabase Auth user, using the publishable key and RLS; the dashboard shows its status through the hub. Realtime, server-side delivery confirmation and protected local storage are not implemented. |
| Repository | Monorepo + Compose + CI | Existing `watch/` and `hub/` form a small monorepo. Foundation adds root Compose, documentation and checks for those applications only. |

## Implemented three-tier flow

```text
Presentation: Wear OS Flutter screen                 Hospital HTML board
                        |                                  |
Application: Vosk -> keyword parser -> report        Express routes + ingest
                        |                                  |
Data:        watch SQLite -> automatic HTTP LAN POST -> hospital SQLite
                  |                   <- ACK IDs --        |
                  +-> Supabase upsert (authenticated, per-user RLS)
                                                   SSE event / poll
```

`watch/lib/main.dart` opens SQLite and the speech engine, records a transcript,
parses it, saves a row, then shows the saved card and haptic feedback. Empty speech
is not saved; nonempty unrecognized speech is saved as `Unassessed`. After SQLite save, automatic transport is attempted independently; an unreachable hub retains the queue. Speech needs a separately provisioned Vosk model ZIP.
The default asset path selects the English model; model language accuracy,
watch RAM, permissions and startup behavior require real-device testing.

`watch/lib/services/sync_service.dart` sends pending rows in bounded batches to
`POST /api/sync-triage`, with an eight-second timeout. Only returned `ackLocalIds`
are marked synced. `hub/sync.js` validates each report and ingests valid rows in
a transaction. Identical duplicate reports are also acknowledged; different immutable originals under the same identity are rejected without acknowledgment. `hub/db.js` deduplicates
on watch identity and normalized UTC creation timestamp. Invalid reports stay
pending. The dashboard fetches rows, updates statuses and refreshes through SSE
with a ten-second polling fallback. See `api-contract.md` for the existing API.

`watch/lib/services/cloud_sync_service.dart` separately upserts UUID-keyed
reports to Supabase using the signed-in user's session. SQLite records remain
the local source of truth; cloud sync state does not change LAN sync state.
Reports created while signed out and pre-upgrade rows have no cloud owner.
Uploading those rows requires explicit confirmation to assign them to the
current account. An upload is acknowledged only after Supabase returns the
upserted report IDs.

`hub/cloud.js` is the hub's optional Supabase backup. Devices and the dashboard
never hold Supabase credentials. The hub reads `SUPABASE_URL`,
`SUPABASE_ANON_KEY`, `SUPABASE_HUB_EMAIL` and `SUPABASE_HUB_PASSWORD` from
its git-ignored `.env`, then signs in as a dedicated Supabase Auth user, so RLS
scopes its rows to that account. Secret/service-role keys are refused. Each
received report is queued in `cloud_sync` (migration 0003) with a UUID generated
once and reused for every retry. Only UUIDs that Supabase returns are marked
synced. Offline, timeout, sign-in or server failures keep everything queued with
backoff (interval doubling up to 10 minutes). A row-level 400/409/RLS refusal is
isolated, recorded as rejected and retried only on an explicit dashboard sync.
The immutable source report is uploaded. Hub revisions, overrides and status are
not uploaded. This UUID is distinct from the watch's own cloud UUID, so a report
sent by both routes appears twice in Supabase, once per owning account. A cloud
upload is a backup, not hospital delivery or clinical review.

The hub applies `hub/migrations/0001_initial_schema.sql` transactionally and
tracks its schema with SQLite `PRAGMA user_version`. Version 2 adds related clinical history and backfills every existing report atomically. Existing compatible
databases are adopted and upgraded through version 2 without dropping records; incompatible
unversioned schemas fail explicitly. The watch v2 upgrade is implemented through
sqflite's `onUpgrade`; the Supabase migration is tracked separately by the
Supabase CLI.

## Integrity limits of the prototype

- The watch ID has only four hexadecimal digits. IDs can collide; it is not a
  trusted identity. Both Flutter and native Apple writers now reserve monotonically
  increasing timestamps against persisted rows in a write transaction. A duplicate
  with different normalized content is rejected without ACK; device ID collisions
  still require a coordinated identity migration. These are gaps in the target
  data-integrity guarantee, not solved by the existing replay tests.
- The server caps batches at 500 reports and JSON bodies at 1 MB. The watch sends
  batches of at most 100 rows with a 900 KiB body cap and foreground backoff.
  Long legacy originals remain pending for the teammate storage upgrade. Failure retains the rows.
- Watch acknowledgments are scoped/validated against sent row IDs but remain unauthenticated.
  Current `sync_status = 1` means the configured LAN endpoint returned an ID;
  it does not prove trusted hospital delivery, arrival or clinical review.
- The parser is keyword decision support, not a validated implementation of a
  clinical START assessment. Negation is handled only for walking. One report
  represents one group in one category, not individual patient records.
- No structured name field exists, but arbitrary speech can contain identifying
  information. Raw transcripts, locations and findings remain sensitive data.

## Target extension boundaries

Keep capture and persistence independent of all transports. A future communication
feature can try available authenticated LAN, cloud or BLE routes after local save.
Use one durable globally unique report ID across transports, validate schemas,
retain pending data, deduplicate retries and persist acknowledgment state. Migrate
legacy rows and API callers before retiring their current identity. Do not change
the current wire format merely to match an aspirational schema.

Mobile relay peers must persist complete verified messages before acknowledging
receipt. Design encrypted payloads, authenticated peers, bounded fragments,
expiry/hop controls, replay handling and trusted hospital delivery receipts.
Android/iOS and Wear OS BLE support requires a protocol and a hardware matrix.
Background discovery/advertising and app suspension differ by platform; there is
no guarantee of a continuous multi-hop route or an acknowledgment return route.
See [Apple's background behavior](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
and [Android's background BLE guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background).

Supabase is an eventual online sync route, not a prerequisite for local capture
or an offline hospital hub. The watch saves first to SQLite, assigns each report
a stable UUID, and retries Supabase upserts by that ID. Each local row records
the authenticated account that owned it at capture time; unowned rows from
signed-out capture or before this upgrade require explicit user confirmation
before assignment to an account. Supabase RLS limits each account to its own
rows. The LAN hub remains a separate route with its existing legacy identity.
Realtime, protected local storage/transports and trusted hospital-delivery
semantics are not implemented. Keep server credentials out of clients. An
optional Python/FastAPI AI service or relay simulator is allowed only when
needed; a server AI service cannot satisfy the offline client requirement.
A local LLM extracts explicit facts with uncertainty; deterministic rules and
qualified review govern provisional triage. Decide placement on watch versus
companion phone using measured device memory, battery and latency.

## Repository and operations

Current paths are `watch/`, `hub/`, `docs/` and `fake-watch.sh`. The larger proposed
`apps/`, `services/` and `packages/` layout remains a possible migration, not an
instruction to move working code now. `compose.yaml` includes the existing hub
Compose file, which builds the existing API/production dashboard and local Ollama, plus a development-only Vite frontend through `hub/compose.dev.yaml`, and mounts
`hub/data` at `/data`. Root include requires
[Compose 2.20.3 or later](https://docs.docker.com/compose/how-tos/multiple-compose-files/include/).
Root development uses localhost:3301 with a same-origin API/SSE proxy to hub:3000. The legacy `hub/` entry point serves optimized assets on port 3000 without Vite. Both default to localhost API binding and share that data directory; run only one at a time. See `docker-development.md` for performed checks and platform limits.

Schema ownership and reserved migration paths are in
`database/migrations/README.md`; `openDb` applies numbered hub migrations transactionally.
The local `pr-ci.yml` adds repository/policy validation, formatting, secret scans,
documented HTTP/dashboard contract tests, existing hub/parser tests, Flutter
analysis, syntax checks and Compose/container checks. It adds no Android build.
The original foundation had no complete Apple app targets. Later Qwen app targets are documented below; historical native library builds/recovery tests were simulator checks; speech/model execution, clinical correctness and physical hardware behavior remain unverified. Main protection was applied and verified
through GitHub APIs; publication/hosted execution of the new workflow is pending.
See `GITHUB_WORKFLOW.md` and `../.github/branch-policy.md` for the current gate.
See `reverse-engineering.md` for dated evidence, gaps and the next work order.


## Historical boundary before backend integration — 2026-10-09

The earlier main work assigned Qwen and database implementation to teammates. That historical work added
no database/schema/migration change, model, runtime dependency, application framework
or inference container. `hub/risk.js` owns deterministic priority; `hub/processing.js`
validates the planned extraction envelope. Existing Express/SQLite storage and HTTP
endpoints remain; priority metadata is computed on read. Extended metadata is refused
without ACK until durable storage can preserve it. Audited corrections/overrides are
not implemented in that earlier work.

`watch/apple` is a native Swift library inside the existing watch application boundary.
`OnDeviceTranscriber` requires local speech support and on-device requests; no network
fallback exists. `FallbackProcessor` separates application recovery from the teammate's
`FallbackRepository` and Qwen/STT processor. A failed commit leaves pending input intact.
These are real library features, not complete native apps or paired Watch transfer.
The watchOS SDK lacks Speech.framework; local Watch STT requires a different proven
runtime. No continuous background execution or physical-device claim is made.

See `implementation-report.md` for current checks/blockers, `qwen-agent-handoff.md`
and `database-team-handoff.md` for integration ownership, and `windows-qa.md` for
isolated hospital QA. The original target remains approved but incomplete.


## Backend integration update — 2026-10-09

The current request authorizes the previously deferred database and backend work.
Hub schema v2 integrates structured processing v1, original submissions, patient
and encounter records, optimistic/idempotent corrections, computed classification
history and operator overrides. Existing rules remain provisional; no new clinical
thresholds, protocol, model runtime or treatment algorithm is added. Machine claims
are preserved with provenance but excluded from established assessment inputs until
qualified non-model reassessment. Automatic submission has no manual gate.

The current watch queue preserves exact originals and creates timestamps inside
its write transaction using the persisted maximum. LAN transmission starts only
after save and uses byte-aware batches; failed or over-limit transfers retain rows.
Only validated ACK IDs from that request change LAN sync state. Source UUID metadata
is additive and does not replace legacy LAN identity.

`GET /api/triage` reads the latest persisted assessment in one joined query; the
existing dashboard displays uncertainty, immutable source categories, corrections,
rule reasons and operator overrides. Detail/history and patient/encounter endpoints
are implemented inside the same modular monolith. Transcript corrections invalidate
stale findings and overrides; readiness suggestions no longer use invalidated source
findings. See `api-contract.md` and `backend-completion.md` for schema, lifecycle,
checks performed for this request and unresolved clinical/platform requirements.


## Qwen implementation update — 2026-10-09

`models/qwen3-0.6b` contains the actual pinned 396,705,472-byte Q4_K_M conversion
of official Qwen3-0.6B, tracked with Git LFS. GGUF embeds tokenizer/metadata;
manifest, SHA-256 and licenses are local. Explicit initial setup prepares weights,
images and native runtime; normal startup never downloads models.

The hub verifies artifact and imported Ollama blob identity before extraction.
`/api/ai/health` generates fresh tokens; `/api/ai/status` retains an exact-tag check.
A report's `/api/triage/:id/ai-extract` appends idempotent/optimistic extraction to
existing SQLite v2 history; concurrent corrections reject stale output. Original
transcripts, explicit encounters and provenance are preserved. Machine claims
cannot establish clinical urgency; automatic saving has no manual approval gate.
Docker adds an internal-only Ollama runtime with read-only model mounts and a
separate imported-model volume. Existing hub services/data paths remain intact.

`watch/apple/Vanguard.xcodeproj` supplies iOS/watchOS SwiftUI apps. `QwenEngine`
uses vendored CPU llama.cpp, bounded native contexts, cached loading, actor execution,
cancellation/deadlines and physical-device memory preflight. Native captures and
original speech are saved to a separate sandbox SQLite file before inference or
relay. Failed work remains pending; explicit LAN ACKs alone advance hospital
receipt state. Watch attempts local text inference first and optionally transfers
pending text/audio to iPhone through Watch Connectivity. Watch offline STT remains
unimplemented; on-device iPhone Speech support depends on hardware/locale assets.

Both simulator apps generated real tokens and persisted synthetic processing.
The actual Watch device target also compiled unsigned against its SDK. These checks
do not prove physical Watch memory, speech, thermals, background transfer or delivery.
See `QWEN_INTEGRATION.md`, `QWEN_AUDIT.md` and `QWEN_RESULTS.md` for exact status,
resource measurements, setup and scripts. The system remains a synthetic prototype
with unauthenticated HTTP and unencrypted storage, not a real-patient deployment.


## Global connectivity update — 2026-10-10

See `global-ai-connectivity.md` for current verification and remaining acceptance
blockers. Root and legacy Compose now initialize a named verified-weights volume
from existing GGUF bytes or a pinned first-time download, without host Ollama/LFS.
Ollama retains its internal network and imported-model volume; SQLite paths and
clinical schema remain compatible; main's cloud backup migration is preserved. Earlier statements above that require prior checkout
weights for Docker startup are historical.

The web central client uses same-origin requests, UUID request headers, token-aware
SSE/polling and an account-scoped durable outbox with one atomic key per report.
Original capture is saved before inference; generated metadata is validated and
hospital transmission is automatic. Failed extraction can submit an Unassessed
original. Only an explicit scoped receipt removes an outbox entry.

Apple Qwen stays entirely local. Shared readiness states measure token generation;
LAN URL validation, device credentials, bounded foreground retries and receipt
validation are separate. Native tokens use Keychain. iPhone transcribes locally
when the Speech runtime/locale supports it; Watch audio uses the existing paired
fallback because Watch offline STT is still unimplemented. Hardware execution is
unverified. Manual URL/token pairing is the reliable LAN configuration fallback;
automatic Bonjour discovery is not implemented across Docker/native networks.

LAN binding now requires server-side per-user/device credentials. Device principals
can submit only their assigned watch IDs and cannot read hospital records; operators
share the hospital board intentionally. Existing anonymous synthetic localhost use
remains compatible. Authenticated status/correction events record the operator ID.
HTTP and local storage remain unencrypted; credentials alone do not establish
patient-data safety or clinical validity.
