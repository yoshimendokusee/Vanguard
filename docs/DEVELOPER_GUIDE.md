# Vanguard-Wrist Developer Guide

**Prototype reference, reconciled 2026-10-09.** Read
[architecture.md](architecture.md) for the approved target versus actual code,
[api-contract.md](api-contract.md) for the current LAN contract and
[reverse-engineering.md](reverse-engineering.md) for checks run in this audit.
Historical verification below is prior documentation, not evidence of current
hardware execution. The approved target extends the scope described here.

Everything a new contributor needs: what the system does, how the pieces fit, the data
contracts between them, how to run and test each part, how to extend it safely, and what is
still unverified. For a quick start and the demo script, see the [README](../README.md).

**Contents**
1. [Purpose and scope](#1-purpose-and-scope)
2. [Architecture](#2-architecture)
3. [Repository layout](#3-repository-layout)
4. [Feature reference](#4-feature-reference)
5. [The triage pipeline (NLP)](#5-the-triage-pipeline-nlp)
6. [Data model](#6-data-model)
7. [Sync protocol and HTTP API](#7-sync-protocol-and-http-api)
8. [Configuration reference](#8-configuration-reference)
9. [Setup, run, test](#9-setup-run-test)
10. [Extending the system](#10-extending-the-system)
11. [Deployment and network setup](#11-deployment-and-network-setup)
12. [Security and privacy](#12-security-and-privacy)
13. [Verification status and known limitations](#13-verification-status-and-known-limitations)
14. [Troubleshooting](#14-troubleshooting)
15. [Roadmap ideas](#15-roadmap-ideas)

---

## 1. Purpose and scope

During severe floods, cloud infrastructure and cellular networks fail, but hospitals still
need to know **what is coming** before boats and trucks arrive. Vanguard-Wrist lets a rescuer
dictate a patient report to a wrist-worn device that works with **no internet**, and delivers
it to a hospital emergency department as soon as the two share a local Wi-Fi network.

Design principles, in priority order:

1. **Never lose a report.** Everything is written to local storage first. Speech that can't be
   understood is still saved (as *Unassessed*). Sync is retry-safe.
2. **Work with no network.** All speech recognition and parsing run on the watch. The hub
   runs on a laptop with no internet access and no CDN dependencies.
3. **Err toward over-triage.** When ambiguous, pick the more urgent category.
4. **Operate with gloves and no screen.** One big tap target; haptic confirmation.
5. **Stay simple and inspectable.** The "AI" is a deterministic keyword pipeline, because a
   large language model does not fit on a watch and cannot be audited the same way.

**In scope:** medical triage reports from rescuers to a hospital: patient count, age group,
findings, START category, pickup location, ETA.
**Out of scope:** rescue dispatch/logistics (boats, rope, food), patient identity or medical
records, routing between multiple hospitals. Supabase authentication applies only to
optional cloud report sync; the LAN hub remains unauthenticated.

> ⚠ This is a hackathon-grade prototype and decision-support tool. It is **not** a validated
> clinical triage system. A clinician must confirm every patient on arrival.

---

## 2. Architecture

```
 ┌──────────────── Wear OS watch (offline) ────────────────┐        ┌──── Hospital laptop (offline) ────┐
 │                                                          │        │                                    │
 │  mic ─▶ Vosk STT ─▶ TriageParser ─▶ SQLite triage_logs   │  HTTP  │  Express ─▶ SQLite triage_reports  │
 │         (speech_     (nlp/            (db/triage_db)     │ ─────▶ │  /api/sync-triage    │             │
 │          service)    triage_parser)         │            │  LAN   │                      ▼             │
 │                                             ▼            │        │             SSE push ─▶ ED board   │
 │                        SyncService (HTTP) + Supabase    │        │              (public/index.html)   │
 └──────────────────────────────────────────────────────────┘        └────────────────────────────────────┘
        └── haptics confirm save ──┘             both joined to the same internet-free Wi-Fi router
```

**Report lifecycle**

```mermaid
sequenceDiagram
    participant R as Rescuer
    participant W as Watch app
    participant DB as Watch SQLite
    participant H as Hub (Express)
    participant S as Supabase
    participant ED as ED board

    R->>W: tap, speak, tap
    W->>W: Vosk transcript → TriageParser
    W->>DB: INSERT (sync_status = 0)
    Note over W,DB: cloud owner is captured from the signed-in account; otherwise remains unassigned
    W-->>R: haptic pattern (saved / immediate / unrecognized)
    Note over W,H: later, when both are on the same Wi-Fi
    R->>W: tap SEND TO HOSPITAL
    W->>H: POST /api/sync-triage {watchId, reports[]}
    H->>H: validate, INSERT OR IGNORE (dedupe on watch_id+created_at)
    H-->>W: {ackLocalIds, inserted, duplicates, rejected}
    W->>DB: UPDATE sync_status = 1 for acked ids only
    H-->>ED: SSE "triage" event → board reloads
    opt when online and signed in
        W->>S: authenticated upsert by report UUID
        S-->>W: upserted report UUIDs
        W->>DB: UPDATE cloud_sync_status = 1 for acknowledged UUIDs
    end
```

**Key architectural decisions**

| Decision | Why |
|---|---|
| Parsing on the watch, not the hub | The watch must show the rescuer what it understood and buzz immediately, even if it never reaches a hub. The hub stays a thin store. |
| Deterministic keyword matcher instead of an LLM | Fits in memory and a 24-hour build; behaviour is predictable and unit-testable; failure modes are visible. |
| Idempotent sync keyed on `(watch_id, created_at)` | Flaky Wi-Fi means batches get re-sent. A duplicate report would make the ED prepare for patients who don't exist. |
| Ack-based sync (`ackLocalIds`) | The watch only marks a row sent when the hub confirms it. A dropped connection just means "send again". |
| Server-Sent Events, not WebSockets | One-way push is all the board needs; no extra dependency; auto-reconnect is built into `EventSource`. A 10-second poll is the fallback. |
| Hub UI is one static HTML file with no CDN | It must load with zero internet. |
| Unknown speech → *Unassessed*, ranked just after Immediate | An unintelligible report could be a critical patient; hiding it would be the worst failure. |

---

## 3. Repository layout

```
vanguard-wrist/
├── README.md                  Quick start, demo script
├── docs/DEVELOPER_GUIDE.md    This file
├── fake-watch.sh              curl stand-in for a watch
├── watch/                     Flutter app (Wear OS)
│   ├── pubspec.yaml
│   ├── assets/models/         Put the Vosk model .zip here (not committed)
│   ├── lib/
│   │   ├── main.dart          UI, state machine, haptics
│   │   ├── nlp/triage_parser.dart      Pure-Dart parser (no Flutter imports)
│   │   ├── db/triage_db.dart           sqflite queue + watch ID
│   │   └── services/
│   │       ├── speech_service.dart     Vosk wrapper (OfflineSpeech)
│   │       ├── sync_service.dart       Hospital LAN sync client
│   │       └── cloud_sync_service.dart Supabase Auth + cloud sync
│   ├── test/                         Parser and cloud payload tests
│   └── android/               Manifest + Gradle (Wear OS config)
└── hub/                       Node.js hospital hub
    ├── server.js              Express app, routes, SSE (exports createApp)
    ├── sync.js                Validation + idempotent ingest
    ├── db.js                  SQLite schema (openDb)
    ├── sync.test.js           7 integration tests (node:test)
    ├── public/index.html      ED pre-arrival board (vanilla JS, no deps)
    ├── Dockerfile, docker-compose.yml
    └── data/                  SQLite file lives here (volume-mounted in Docker)
```

---

## 4. Feature reference

### 4.1 Watch app

| Feature | Behaviour | Code |
|---|---|---|
| **Single-tap dictation** | Large full-screen mic button toggles listening. Idle = cyan, listening = red with a stop icon. Cyan is deliberate: red/yellow/green are reserved for triage categories. | `main.dart` `_toggle` |
| **Live transcript** | Vosk *partial* results update a scrolling text area in real time; the view auto-follows the newest words. Final results are appended per utterance. | `speech_service.dart`, `main.dart` |
| **Parse and save** | On stop: transcript → `TriageParser.parse` → `TriageDb.insert` → haptic → result card (category colour, `×N`, age, findings, location, ETA). | `main.dart` `_process` |
| **Haptic feedback** | See table below. Lets a rescuer confirm a save without looking at the screen. | `main.dart` `_buzz` |
| **Offline queue** | Every report is stored in SQLite with `sync_status = 0` and an automatic UTC timestamp. | `triage_db.dart` |
| **Send to hospital** | Sends all unsent rows; shows `SENT n (m dup)`, or a short error (`NO HOSPITAL HUB ON NETWORK`, `HUB UNREACHABLE`, …). Disabled while listening or already sending. | `sync_service.dart` |
| **Supabase sync** | Separately upserts signed-in user's pending rows in batches of 100 by UUID. Cloud sync state is independent of hub sync. Offline and failed uploads remain pending; sign-in, local save, startup and the ONLINE button trigger sync. | `cloud_sync_service.dart` |
| **Cloud ownership** | A report captures the current Supabase user ID locally. Unowned rows require explicit confirmation before assignment/upload; rows owned by another user are excluded. | `triage_db.dart`, `main.dart` |
| **Watch ID** | A random `W-XXXX` ID is generated on first launch and persisted in a `meta` table. Shown in the header. | `triage_db.dart` |
| **Demo phrase** | Long-press the header (`W-XXXX · N PENDING`) while idle to run a built-in sample report with no microphone. | `main.dart` `_demoPhrase` |

**Haptic patterns** (milliseconds, `vibration` package)

| Meaning | Pattern | Feel |
|---|---|---|
| Saved (non-Immediate), or sync succeeded | `[0,150,100,150]` | 2 short |
| Saved as **Immediate** | `[0,300,100,300,100,300]` | 3 long |
| Saved but **not understood** (Unassessed) | `[0,80,80,80,80,80,80,80]` | 4 rapid: repeat or verify |
| Nothing heard (empty transcript, nothing saved) | `700` | 1 long |

**Triage colours** (`triageColor` in `main.dart`, mirrored in the hub CSS): Immediate red
`#FF1744`, Delayed yellow `#FFD600`, Minor green `#00E676`, Deceased grey `#B0BEC5`,
Unassessed white.

### 4.2 Hospital hub

| Feature | Behaviour | Code |
|---|---|---|
| **Bulk sync endpoint** | `POST /api/sync-triage` takes up to 500 reports; validates each; inserts atomically in one transaction. | `server.js`, `sync.js` |
| **Duplicate protection** | `UNIQUE(watch_id, created_at)` plus `INSERT OR IGNORE`. Duplicates are skipped *and* acknowledged. Timestamps are normalised to canonical ISO first, so `…00.1Z` and `…00.100Z` collide. | `sync.js`, `db.js` |
| **Pre-arrival board** | Live-updating ED view in a teal dashboard layout: a rail with the status tabs (On the way, Arrived, Cancelled, All reports); a left column with the "Next to arrive" card (countdown, readiness checklist, **Mark arrived**), "Due within 30 minutes" and "Teams to alert"; and a main panel with search, a category filter, a summary line, three "Coming up" cards, an arrivals curve (15 min / 30 min / 1 h / 3 h) and the patient list. Tab, category and search are kept in the URL. Stacks under 1180 px. Light, dark and auto themes, Poppins if installed, no external assets. | `public/index.html` |
| **Acuity ordering** | Still-inbound first; then Immediate → Unassessed → Delayed → Minor → Deceased; then soonest expected arrival (reports with no ETA last within a category). | `server.js` `GET /api/triage` |
| **Category counts** | Patients (not reports) per category for the current tab, shown on the category filter chips and in the summary line. Counts sum `patient_count`. "Not sure" is the plain-language label for `Unassessed`. | `index.html` `renderCats`, `renderSummary` |
| **Teams to alert** | Maps each finding to resources (e.g. Severe bleeding → Blood/OR) and totals patients per resource. Adds Paediatrics for Child/Infant. Deceased reports are excluded. The same mapping drives the readiness checklist on the "Next to arrive" card (ticks are saved in that browser only, not on the hub). | `index.html` `PREP`, `renderPrep`, `readyItems` |
| **"Due within 30 min"** | Count of non-deceased patients whose ETA is ≤ 30 min away (including overdue). | `index.html` |
| **ETA countdown** | `created_at + eta_minutes` vs the browser clock: `N min`, then "arriving soon", then `+N min past ETA`. If the watch clock is badly wrong (more than 7 days before or 2 hours after receipt) the countdown runs from the hub receipt time and says so. Re-rendered every 15 s. | `index.html` `timeBlock`, `badClock` |
| **Arrivals curve** | Expected arrivals over a chosen window, solid for everyone and dashed for Immediate. Patients already past their ETA are counted at "Now"; later or no-ETA patients are listed under the chart. Has a spoken summary and redraws on resize. Approximate, because it depends on watch clocks. | `index.html` `renderCurve` |
| **Status actions** | Inbound → Arrived / Cancelled, and Reopen, through the card. The pressed button shows a spinner and is disabled until the hub answers; a failure shows a toast. Arrived and cancelled reports move to their own tabs. | `PATCH /api/triage/:id` |
| **Live push** | `GET /api/events` (SSE) emits `triage` events on insert/update; the board reloads. 10 s poll as a safety net; "LIVE / reconnecting" indicator. | `server.js` |
| **Hospital name** | `HOSPITAL_NAME` env var, served at `/api/config`. | `server.js` |
| **XSS-safe rendering** | Transcripts are untrusted text; the board only uses `textContent`, never `innerHTML`. Keep it that way. | `index.html` `el()` |

---

## 5. The triage pipeline (NLP)

File: [`watch/lib/nlp/triage_parser.dart`](../watch/lib/nlp/triage_parser.dart). It is **pure
Dart** (no Flutter imports) so it unit-tests with `flutter test` in milliseconds and could
be reused on a phone or server.

### 5.1 Stages

`TriageParser.parse(String transcript) → TriageResult`

1. **Tokenize:** lowercase; replace anything outside `a-z ñ 0-9 whitespace` with a space;
   split on whitespace. Note `can't` → `can t`, so phrase lists are written as `can t walk`.
2. **Findings:** for each entry in the injury table, test every variant phrase with a
   sliding-window match (§5.2). Collect the entries that matched.
3. **Supersession:** drop generic findings hidden by a more specific one that also matched
   (e.g. *Severe bleeding* hides *Bleeding*; *Laceration* and *Head injury* hide *Wound*;
   *Abrasion* hides *Wound* and *Bleeding*; *Non-ambulatory* hides *Ambulatory*).
4. **Category:** worst surviving tier wins: any Immediate → **Immediate**; else any Delayed →
   **Delayed**; else any Minor → **Minor**; else Deceased → **Deceased**; no findings →
   **Unassessed**. Deceased therefore never hides a live patient.
5. **Extras:** location, patient count, age group, ETA (§5.3).

`TriageResult` fields: `location`, `injuries` (list), `triage`, `patientCount`, `ageGroup`,
`etaMinutes` (nullable), `rawText`. `isRecognized` is true iff `injuries` is non-empty.
`injuriesText` is the comma-joined list, or `Unspecified`.

### 5.2 Fuzzy matching

A token matches a keyword if equal, or within a small Levenshtein distance that depends on
the **keyword** length: **≥ 10 letters → 2 edits, ≥ 7 → 1 edit, < 7 → exact only.**

Why so strict: offline Tagalog STT does mangle words, but short Tagalog words are often one
letter from an unrelated word: *nabali* (fractured) vs *nabalik* (returned). The threshold is
a deliberate false-positive guard; there is a test for it. Multi-word phrases match
word-by-word, in order, and adjacent.

### 5.3 Extractors

| Extractor | Rule |
|---|---|
| **Location** | First entry in `TriageParser.locations` whose phrase matches → `Barangay <Name>`; otherwise `Unknown`. |
| **Patient count** | First number token (digits, or Tagalog/English word 1–60 from `_numberWords`) followed by a person word (`_personWords`), optionally with a linker `na` ("dalawa na bata"). Range 1–99. Default **1**. |
| **Age group** | Infant (`sanggol`, `baby`…) > Child (`bata`, `anak`, `child`…) > Elderly (`lolo`, `lola`, `matanda`, `elderly`…) > Adult (`adult`) > `Unspecified`. Note `matanda` maps to Elderly. |
| **ETA** | Number followed by a minute word → minutes; by an hour word (`oras`, `hour`) → ×60; `kalahating oras` / `half hour` → 30. Accepted range 1–720 minutes; otherwise `null`. |

### 5.4 Findings and tiers

| Tier | Finding (canonical name) | Example spoken variants |
|---|---|---|
| **Immediate** | Not breathing | hindi humihinga, walang pulso |
| | Difficulty breathing | hirap huminga, hinihingal |
| | Drowning | nalunod, nalulunod, lunod |
| | Unconscious | walang malay, unresponsive |
| | Severe bleeding | malakas na pagdurugo, duguan, hemorrhage |
| | Head injury | nabagok, sugat sa ulo |
| | Chest pain | masakit ang dibdib, heart attack |
| | Electrocution | nakuryente, kuryente |
| | Pregnant / labor | buntis, manganganak |
| **Delayed** | Fracture | nabali, bali, broken leg |
| | Laceration | malalim na sugat, nahiwa, deep cut |
| | Bleeding | dumudugo, bleeding |
| | Wound | sugat, sugatan, injured |
| | Hypothermia | nilalamig, giniginaw |
| | Burn | napaso, nasunog |
| | Snakebite | tinuklaw, ahas |
| | Weak / dehydrated | nanghihina, mahina |
| | Non-ambulatory | hindi makalakad, cannot walk |
| **Minor** | Abrasion | gasgas, galos, maliit na sugat |
| | Ambulatory | nakakalakad, can walk |
| **Deceased** | Deceased | patay, namatay, wala nang buhay |

The authoritative list is `_injuries` in the source; this table is a summary.

### 5.5 Behavioural guarantees (covered by tests)

- The sample sentence yields Immediate ×2 Child, `[Drowning, Unconscious]`, Barangay Arnaldo, ETA 10.
- "Cannot walk" is Delayed, never Minor.
- Worst finding wins; Deceased only when nothing else matches.
- *Nabalik* does not match *Fracture*.
- Speech with no keywords → `Unassessed`, `isRecognized == false`, raw text preserved.
- Empty input does not throw; patient count is 1.

### 5.6 Known gaps

- One report = one patient group in one category. Mixed groups must be spoken as separate reports.
- **Negation is only handled for walking.** "Hindi dumudugo" (not bleeding) still matches *Bleeding*.
  Over-triage is the intended failure mode, but be aware of it.
- No quantity-per-finding ("one with a fracture, two with cuts").
- Patient count scans for `number + person-word`; unusual phrasing falls back to 1.

---

## 6. Data model

### 6.1 Watch: `triage_logs` (sqflite, DB file `vanguard.db`, schema version 2)

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | Sent to the hub as `localId`. |
| `location` | TEXT | `Barangay X` or `Unknown`. |
| `injuries` | TEXT | Comma-joined canonical names, or `Unspecified`. |
| `triage` | TEXT | `Immediate` / `Delayed` / `Minor` / `Deceased` / `Unassessed`. |
| `patient_count` | INTEGER | Default 1. |
| `age_group` | TEXT | `Infant` / `Child` / `Adult` / `Elderly` / `Unspecified`. |
| `eta_minutes` | INTEGER | Nullable; minutes after `created_at`. |
| `raw_text` | TEXT | Original transcript, always kept. |
| `created_at` | TEXT | ISO-8601 UTC, millisecond precision. Increasing within one process (the insert bumps by 1 ms); the last timestamp is not restored after restart. Half of the hub's idempotency key. |
| `sync_status` | INTEGER | `0` = unsent, `1` = hub acknowledged. |
| `report_id` | TEXT | Stable UUID used as the Supabase idempotency key. |
| `cloud_owner_id` | TEXT, nullable | Supabase Auth user ID captured at local save, or assigned after explicit confirmation for unowned rows. |
| `cloud_sync_status` | INTEGER | `0` = not acknowledged by Supabase, `1` = cloud upsert returned this UUID. Independent of `sync_status`. |

Plus `meta(key, value)` holding `watch_id`. The other half of the idempotency key.
Version-1 rows are upgraded in place with new UUIDs and remain locally queued.
Their cloud owner remains null until a signed-in user explicitly confirms assignment.

### 6.2 Hub: `triage_reports` (SQLite, `better-sqlite3`, WAL mode)

Same fields, snake_case, plus:

| Column | Notes |
|---|---|
| `watch_id` | From the request. Trimmed, max 64 chars. |
| `received_at` | Hub clock (ISO UTC) at ingest. |
| `status` | `inbound` (default) / `arrived` / `cancelled`. |
| constraints | `CHECK` on `triage`, `status`, `patient_count BETWEEN 1 AND 99`; `UNIQUE(watch_id, created_at)`. |
| schema version | `PRAGMA user_version`; baseline SQL is `hub/migrations/0001_initial_schema.sql`. |

Two clocks are stored on purpose: `created_at` is *when the rescuer spoke* (watch clock),
`received_at` is *when the hub heard* (hub clock). The gap is the offline delay.

> **Migration status.** The watch upgrades version-1 databases to version 2 in place,
> adding stable report UUIDs and separate cloud ownership/sync columns. The hub
> applies numbered SQL migrations transactionally and adopts compatible legacy
> databases without dropping reports. Follow
> [the migration guide](../database/migrations/README.md) for future changes.
> Never wipe a persistent database as an upgrade strategy.

---

## 7. Sync protocol and HTTP API

All bodies are JSON. The hub listens on `0.0.0.0:3000` by default.

### 7.1 `POST /api/sync-triage`

Request:

```json
{
  "watchId": "W-1A2B",
  "reports": [{
    "localId": 7,
    "location": "Barangay Arnaldo",
    "injuries": "Drowning, Unconscious",
    "triage": "Immediate",
    "patientCount": 2,
    "ageGroup": "Child",
    "etaMinutes": 10,
    "rawText": "Dalawang bata, nalunod at walang malay…",
    "createdAt": "2026-10-09T06:00:00.123Z"
  }]
}
```

Per-report validation (`hub/sync.js`):

| Field | Rule |
|---|---|
| `createdAt` | Required, parseable date. Normalised with `toISOString()`. |
| `triage` | Required, one of the 5 categories. |
| `patientCount` | Integer 1–99; defaults to 1 if absent. |
| `ageGroup` | One of 5 values; defaults to `Unspecified`. |
| `etaMinutes` | `null`/absent, or integer 1–720. |
| `location`, `injuries` | Required, non-empty after trim; truncated to 200 / 300 chars. |
| `rawText` | Optional; truncated to 1000 chars. |
| `localId` | Integer, echoed back in `ackLocalIds`. |

Response `200`:

```json
{ "ok": true, "inserted": 1, "duplicates": 0, "rejected": [], "ackLocalIds": [7] }
```

**Acknowledgement semantics: the heart of sync correctness.**

| Outcome for a report | In `ackLocalIds`? | Watch behaviour |
|---|---|---|
| Inserted | ✅ | Marked sent. |
| Duplicate (already stored) | ✅ | Marked sent. The hub has it; stop resending. |
| Rejected (invalid) | ❌ (listed in `rejected` with a reason) | Stays queued; will be retried (and rejected again) until fixed. |

Errors: `400` `{ok:false,error}` if `watchId` is missing/not a string or `reports` isn't an
array; `413` if more than 500 reports. The watch treats any non-200 as failure and keeps
all rows queued; the client times out after 8 s.

### 7.2 Other endpoints

| Method & path | Purpose |
|---|---|
| `GET /api/triage` | All reports (snake_case rows), already in ED priority order. |
| `PATCH /api/triage/:id` | Body `{ "status": "inbound" \| "arrived" \| "cancelled" }`. `400` bad status, `404` unknown id. Emits an SSE event. |
| `GET /api/events` | SSE stream. Event name `triage`, data `{inserted: n}` or `{updated: id}`. 20 s keep-alive comments. |
| `GET /api/health` | `{ok:true,time}`. Handy for "is the hub reachable?" checks. |
| `GET /api/config` | `{hospital}`. |
| `GET /` | The ED board (static). |

Try it without a watch: `./fake-watch.sh http://localhost:3000`. It stamps the current
minute, so a second run in the same minute is a duplicate and a later run is a new patient.

---

## 8. Configuration reference

| Setting | Where | Default | Purpose |
|---|---|---|---|
| `HUB_URL` | `--dart-define` (watch) | `http://192.168.8.10:3000` | Where the watch sends reports. **Compile-time**, so rebuild to change it. |
| `VOSK_MODEL` | `--dart-define` (watch) | `assets/models/vosk-model-small-en-us-0.15.zip` | Which bundled Vosk model zip to load. |
| `SUPABASE_URL` | `--dart-define` (watch) | unset | Supabase project URL; must use HTTPS. |
| `SUPABASE_ANON_KEY` | `--dart-define` (watch) | unset | Supabase publishable/anon key. Never use a service-role key in a client. |
| `PORT` | env (hub) | `3000` | Listen port. |
| `HOST` | env (hub) | `0.0.0.0` | Listen address; use `127.0.0.1` for local-only access. |
| `DB_PATH` | env (hub) | `hub/data/vanguard.db` (`/data/vanguard.db` in Docker) | SQLite file. `:memory:` works (used by tests). |
| `HOSPITAL_NAME` | env (hub) | `Receiving Hospital · Emergency Department` | Board title. |

Android (`watch/android/app/src/main/AndroidManifest.xml`, `build.gradle.kts`):

| Item | Value | Reason |
|---|---|---|
| `minSdk` | 26 | Wear OS 2 devices are API 25–28, Wear OS 3+ is 30+; Vosk needs ≥ 21. |
| Permissions | `RECORD_AUDIO`, `INTERNET`, `ACCESS_NETWORK_STATE`, `VIBRATE` | Mic, LAN HTTP, haptics. |
| `usesCleartextTraffic` | `true` | The LAN hub is plain HTTP (no TLS on a sealed router). |
| `uses-feature type.watch` + `wearable.standalone = true` | | Marks it a standalone Wear OS app (no phone companion). |

---

## 9. Setup, run, test

**Prerequisites:** Flutter (Dart ≥ 3.13) and an Android SDK for the watch; **Node ≥ 22** for
the hub (`better-sqlite3` 13 requires it); Docker optional. Supabase cloud sync also
requires a project with the checked-in schema migration applied and email Auth enabled.

Apply the Supabase migration to the intended project using the procedure in
`supabase/migrations/README.md`. Configure the watch at build/run time with
`SUPABASE_URL` and `SUPABASE_ANON_KEY`. The watch can still capture locally when
these are unset; cloud sync is disabled.

### Hub

```bash
cd hub
npm ci
npm test                                  # 9 tests, synthetic in-memory/temporary SQLite and loopback HTTP
HOST=127.0.0.1 npm start                  # local-only at http://localhost:3000
npm start                                 # all interfaces; prints LAN URLs
HOSPITAL_NAME="St. Luke's ED" PORT=4000 npm start
docker compose up --build                 # build once while online; image runs offline
```

### Watch

```bash
cd watch
flutter pub get
flutter analyze
flutter test                              # parser, migration and cloud payload tests
flutter run --dart-define=HUB_URL=http://<hub-ip>:3000 \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable-or-anon-key>
```

Apply the migration in `supabase/migrations/` to your project and enable email
authentication before supplying the URL and publishable/anon key. Cloud sync
remains optional; do not pass a service-role key to the watch app.

Speech model: download a zip from <https://alphacephei.com/vosk/models> into
`watch/assets/models/` (the folder is declared in `pubspec.yaml`; zips are git-ignored).
The app unpacks it to app storage on first launch, so the first start is slow.

### What the tests cover

| Suite | Covers | Does **not** cover |
|---|---|---|
| `watch/test/triage_parser_test.dart` | Every extractor, tier precedence, supersession, fuzzy-match guard, empty/garbage input. | UI, DB, speech, sync client. |
| `watch/test/triage_db_migration_test.dart` | Upgrading/reopening a populated v1 SQLite database, preserving watch ID/report fields/hub sync state, generating UUIDs/default cloud state, and rollback on migration DDL failure. | Android SQLite behavior and real storage-device failures. |
| `watch/test/cloud_sync_service_test.dart` | Supabase payload field mapping and stable report UUID. | Live Auth, network retries, remote RLS policies. |
| `hub/db.test.js` | Fresh schema migration, idempotent reopen, populated legacy DB adoption, incompatible-schema rejection, and transactional rollback. | Production hub database backup/restore procedures. |
| `hub/sync.test.js` | Ingest, ack semantics, duplicate and cross-watch handling, timestamp normalisation, validation/rejection, defaults, ordering, status endpoint. | SSE, static board, Docker, concurrency, the browser UI. |
| `hub/contract.test.js` | Documented API request/response, sender fields, served dashboard JS syntax, SSE headers, populated hub reopen/deduplication. | Browser rendering, speech/native hardware, future schema upgrades. |

**Conventions:** keep `triage_parser.dart` free of Flutter imports; add a test with every
vocabulary change; hub tests open `openDb(':memory:')` and call `createApp(db)`, so no files or
fixed ports.

---

## 10. Extending the system

### Add a medical finding

1. Add a `_Injury(name, tier, variants, supersedes: …)` entry in `triage_parser.dart`.
   Lowercase, no punctuation; use `can t` for `can't`. Mind the fuzzy-match thresholds for
   words under 7 letters.
2. Add a test (positive match, and a look-alike that must *not* match if the word is short).
3. **Add a matching key to `PREP` in `hub/public/index.html`** if the ED should prepare
   something. ⚠ **The canonical `name` is a contract:** `PREP` is keyed by those exact strings
   (`Severe bleeding`, `Pregnant / labor`, …). A typo silently drops the finding from the
   "Prepare for" panel. The hub stores `injuries` as free text and does not validate names.

### Add or change locations

Edit `TriageParser.locations` (canonical name → spoken variants). Multi-word names are
matched word-by-word.

### Add a triage category or age group

These are enumerations enforced in several places; update **all** of:

| Place | What |
|---|---|
| `triage_parser.dart` | Constants and `_triageOf`. |
| `hub/sync.js` | `TRIAGE` / `AGE_GROUPS` sets. |
| `hub/db.js` | The `CHECK` constraint, which **needs a migration** for existing databases (§6). |
| `hub/server.js` | The `CASE` in the ORDER BY. |
| `hub/public/index.html` | `TRIAGE` array, summary tiles, CSS colours. |
| `main.dart` | `triageColor`. |

### Add a field (e.g. "mechanism of injury")

Parser → `TriageResult` → `triage_logs` (+ DB `version` bump with `onUpgrade`) → `TriageRow` →
sync payload (`sync_service.dart`) → hub `validateReport` and `INSERT` → schema → board.
Keep new fields **optional with defaults** in `validateReport`, so older watches in the
field can still sync to a newer hub.

### Change what the ED is told to prepare

Only `PREP` in `index.html`. It's advisory, hub-side, and needs no watch update, which is
why resource mapping lives there and not in the parser.

### Support another language

Add variants to the injury table, `_numberWords`, `_personWords`, minute/hour words, and the
age-group map, then use a Vosk model for that language.

---

## 11. Deployment and network setup

**Network:** a travel router with **no uplink**, with DHCP on. Join the hub laptop and each
watch to it. Reserve a fixed IP for the laptop in the router's DHCP settings and bake it in
with `--dart-define=HUB_URL=…`. The URL is compile-time, so a changed IP means a rebuild.

**Hub:** run `docker compose up --build` **once while online** (it runs `npm ci`);
after that the image runs fully offline. Data persists in `hub/data/` via the volume. The
hub logs its LAN addresses at startup. If it started offline with no network interface up,
restart it after joining the router.

**Watch:** sideload a debug or release APK to a Wear OS device, grant the microphone
permission, and start with Wi-Fi joined to the router. Reports can be taken before the
network is available; they sync later.

**Demo checklist:** model unpacked once beforehand (first launch is slow) · microphone
permission granted · hub started · `HUB_URL` points at the laptop's router IP ·
long-press demo phrase tested as a fallback · `./fake-watch.sh` ready as a backup.

---

## 12. Security and privacy

| Topic | State |
|---|---|
| Patient identity | No structured name field. Arbitrary raw transcripts can contain identifying information; findings and locations are sensitive. |
| Transport | Plain HTTP on a closed LAN. No TLS. |
| Authentication | Supabase cloud rows require Auth and RLS and are restricted to their owner. The LAN hub has **no authentication**: anyone with network access can read reports, submit them or change statuses. Synthetic isolated demos only; not acceptable for real patient use or shared/public networks. |
| Input handling | Server-side validation and length caps; board renders with `textContent` (no HTML injection from transcripts). SQL uses prepared statements. |
| Audio | Processed on-device by Vosk; **never stored and never transmitted.** Only the transcript text is saved and sent. |
| Data at rest | Unencrypted SQLite on both the watch and the hub laptop. |

Before any real deployment: authenticate/authorize the LAN hub, protect storage and
transports, define retention, and review privacy law (e.g. the Philippines' Data Privacy Act).

---

## 13. Verification status and known limitations

**Historical verification reported by the original author (not rerun as a browser/hardware check here):** `flutter analyze` (clean); 12 parser tests; 7 hub tests; the real hub running
with seeded data and its board exercised in a browser (ordering, tiles, countdowns,
the Arrived button, live push of a new report without a reload); the watch UI flow (dictate → parse → save → send →
appears on the hub) run through a **web build with in-memory stand-ins for Vosk and SQLite**.

**Historical unverified list; see the dated audit for current Docker verification:**

- Vosk transcription on a real Wear OS device, including model load time and RAM headroom.
- `sqflite` persistence, `vibration` haptics, microphone permission flow.
- The Android build and Wear OS install.
- The Docker image.
- Behaviour when Wi-Fi drops mid-sync on real hardware.

**Limitations to design around**

- **No model is bundled.** The default asset path selects a small English model;
  the [Vosk catalogue](https://alphacephei.com/vosk/models) lists the Filipino model
  `vosk-model-tl-ph-generic-0.6` at 320M. Provision an appropriate asset separately
  and treat speech/Taglish accuracy and watch memory use as unproven until tested.
- **Clock drift:** air-gapped devices have no NTP. ETA countdowns use `created_at` (watch
  clock) against the viewing browser's clock, so a skewed watch skews the countdown.
- **Release builds:** `vosk_flutter` documents JNA ProGuard keep-rules
  (`-keep class com.sun.jna.* { *; }`) if you enable minification; the project doesn't add them.
- **Dependency pins:** `vosk_flutter` 0.3.48 constrains `http` to 0.13.x and
  `permission_handler` to 10.x; don't bump those independently.
- **No hospital routing or multi-hub fan-out.** The LAN hub has no authentication;
  Supabase cloud sync has email/password Auth and per-user RLS.

---

## 14. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Watch shows `HUB UNREACHABLE` / `NO HOSPITAL HUB ON NETWORK` | Wrong `HUB_URL` (it's compile-time); watch not on the router; laptop firewall blocking port 3000; cleartext traffic disabled in the manifest. |
| `SENT 0 (1 dup)` | Normal: the hub already had it. The row is now marked sent. |
| A report never leaves the queue | The hub is rejecting it. Read `rejected[].reason` in the sync response (enum/range violation); it stays queued by design. |
| Watch says `MODEL ERROR` | Model zip missing from `assets/models/` or wrong `VOSK_MODEL` name/path; not enough storage/RAM for the big model. The error text appears in the transcript area. |
| Everything saved as `Unassessed` | STT output has no recognised keywords. With the English model, spoken Tagalog won't match. Check the transcript shown; use the Tagalog model or add variants. |
| A finding doesn't show in "Prepare for" | Its canonical name has no matching key in `PREP` (§10). |
| `npm install` fails building `better-sqlite3` | Old version on a new Node. Use `^13.0.3`; Node ≥ 22. |
| Board says `reconnecting…` | SSE stream dropped; it retries every 2 s and polls every 10 s meanwhile. Check the hub process. |
| Hub crashes on start after a schema change | Old SQLite file with the previous columns. Delete `hub/data/vanguard.db*` (dev) or write a migration. |
| Two reports collapsed into one | Identical normalized `created_at` and `watchId`. Ordering is process-local; clock rollback after restart or colliding four-hex-digit watch IDs can collide. Preserve data and investigate; do not reset storage. |

---

## 15. Roadmap ideas

- **Verify on hardware first:** Vosk on a real watch (and a decision on the Tagalog model
  size problem), haptics, offline sync under real Wi-Fi conditions.
- **Auth and TLS** between watch and hub; encrypted storage and retention policy.
- **Multi-patient reports:** per-category counts in a single utterance ("isang kritikal, dalawang minor").
- **Better negation and context** in the parser ("hindi dumudugo", "walang bali").
- **Dev harness:** a desktop/web build with in-memory fakes for Vosk and SQLite so UI flows can
  run in CI without a device (this was prototyped ad hoc and is not in the repo).
- **Multi-hospital routing** and bed/capacity feedback from the ED to the rescuer's watch.
- **Hub schema migrations** and an export (CSV/FHIR-ish) for after-action review.
- **Auto-sync** when the watch detects the hub's `/api/health`, instead of a manual button.
