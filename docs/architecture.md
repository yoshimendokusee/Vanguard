# Vanguard-Wrist architecture — source of truth

Reconciled with commit `6ef35c4` on 2026-10-09. This document records both the
approved target and the implemented prototype. The target is not a claim of
completion. Keep application paths unchanged until an integration needs a move.

## Approved target

Offline-first modular monolith with distributed edge clients; three-tier
separation; feature-based modules; one monorepo; feature branches, PR review and
GitHub Actions. Docker Compose supports hospital/server development. Watch and
mobile applications use Flutter and native SDKs outside Docker.

| Area | Target | Actual code and gap |
| --- | --- | --- |
| Watch | Offline Wear OS triage | `watch/`: Flutter Android project; Vosk wrapper, deterministic Taglish parser, SQLite queue, haptics and manual LAN send. Hardware execution unverified. |
| Local AI | Offline STT + lightweight local LLM extraction + deterministic triage + human review | Vosk integration and keyword/fuzzy parser exist. No model archive is bundled, no LLM runtime or explicit pre-save review/confirmation screen exists. |
| Mobile | Flutter Android/iOS relay clients | No companion application or iOS project. Watch Android code does not establish mobile support. |
| Offline relay | Authenticated/encrypted BLE store-and-forward | No BLE dependency, permissions, protocol, durable relay queue, fragmentation, hop/expiry controls or return acknowledgment path. |
| Local data | SQLite first on clients and hospital | Watch `triage_logs` + `meta` with sqflite v1→v2 upgrade; hub `triage_reports` with WAL and numbered transactional baseline migrations. Neither database is encrypted; no retention policy. |
| Hospital LAN | Offline receiving API + dashboard | `hub/`: Express, SQLite, static HTML/CSS/JS dashboard, SSE + polling. No external dashboard assets. HTTP without auth/TLS. |
| Backend | Node/Express modular monolith | One small service: `server.js` routes, `sync.js` validation/ingest, `db.js` persistence. Do not split into services. Add feature modules as features arrive. |
| Dashboard | React + TypeScript + Tailwind | Current dashboard is `hub/public/index.html`, with no React/TypeScript/Tailwind dependencies or build step. Retain it until a separately tested replacement exists. |
| Cloud | Supabase PostgreSQL/Auth/Realtime + idempotent sync | Watch has authenticated, owner-scoped upsert sync to `triage_reports` with RLS and a versioned SQL migration. Realtime, server-side delivery confirmation and protected local storage are not implemented. |
| Repository | Monorepo + Compose + CI | Existing `watch/` and `hub/` form a small monorepo. Foundation adds root Compose, documentation and checks for those applications only. |

## Implemented three-tier flow

```text
Presentation: Wear OS Flutter screen                 Hospital HTML board
                        |                                  |
Application: Vosk -> keyword parser -> report        Express routes + ingest
                        |                                  |
Data:        watch SQLite -> HTTP LAN POST -> hospital SQLite
                  |                   <- ACK IDs --        |
                  +-> Supabase upsert (authenticated, per-user RLS)
                                                   SSE event / poll
```

`watch/lib/main.dart` opens SQLite and the speech engine, records a transcript,
parses it, saves a row, then shows the saved card and haptic feedback. Empty speech
is not saved; nonempty unrecognized speech is saved as `Unassessed`. There is no
network call in capture. Speech needs a separately provisioned Vosk model ZIP.
The default asset path selects the English model; model language accuracy,
watch RAM, permissions and startup behavior require real-device testing.

`watch/lib/services/sync_service.dart` sends all pending hospital rows to
`POST /api/sync-triage`, with an eight-second timeout. Only returned `ackLocalIds`
are marked synced. `hub/sync.js` validates each report and ingests valid rows in
a transaction. Duplicate reports are also acknowledged. `hub/db.js` deduplicates
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

The hub applies `hub/migrations/0001_initial_schema.sql` transactionally and
tracks its schema with SQLite `PRAGMA user_version`. Existing compatible
databases are adopted at version 1 without dropping records; incompatible
unversioned schemas fail explicitly. The watch v2 upgrade is implemented through
sqflite's `onUpgrade`; the Supabase migration is tracked separately by the
Supabase CLI.

## Integrity limits of the prototype

- The watch ID has only four hexadecimal digits. IDs can collide; it is not a
  trusted identity. Timestamp monotonicity is only in memory for one process;
  restart plus clock rollback can collide with an old report. A duplicate with
  different content is ignored and acknowledged. These are gaps in the target
  data-integrity guarantee, not solved by the existing replay tests.
- The server caps batches at 500 reports and JSON bodies at 1 MB. The watch sends
  the entire queue, with no batching/backoff/rejection details in its UI; a large
  pending queue can remain unsendable. Failure retains the rows.
- Watch acknowledgments are not authenticated or scoped to the sent row IDs.
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
Compose file, which builds one service containing the API and dashboard and mounts
`hub/data` at `/data`. Root include requires
[Compose 2.20.3 or later](https://docs.docker.com/compose/how-tos/multiple-compose-files/include/).
Both entry points share that data directory; run only one at a time.

Schema ownership and reserved migration paths are in
`database/migrations/README.md`; no migration is applied by this foundation.
CI runs existing hub and watch tests, Flutter analysis, syntax checks, Compose
validation and container build/tests. It does not establish native builds,
speech quality, clinical correctness, BLE reliability or hosted branch protection.
See `reverse-engineering.md` for dated evidence, gaps and the next work order.
