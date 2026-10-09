# Vanguard-Wrist: offline medical triage → hospital pre-arrival

A rescuer taps a Wear OS watch and describes the patient(s) out loud. The watch
transcribes **on-device** (Vosk), extracts a structured medical triage report with a
deterministic Taglish keyword pipeline, queues it in SQLite, and, once it reaches an
internet-free Wi-Fi router, sends it to a Dockerized hospital hub. The ED sees a
live pre-arrival board: how many casualties are coming, how bad, what they need, and
when they arrive. This describes the implemented prototype, not hardware-verified
operation or clinical validation. No speech model is bundled in this checkout.

The approved target adds mobile BLE relay, Supabase sync, local LLM extraction and
a React/TypeScript/Tailwind dashboard. Those components are **not implemented**.
The existing watch, hub and plain HTML dashboard remain in their current paths.

```
vanguard-wrist/
├── AGENTS.md                 AI agent guardrails
├── docs/                     Architecture, actual API, conventions, audit, legacy guide
├── .github/                  PR/issue templates and CI
├── database/migrations/      Reserved watch/hub migration history; no runner yet
├── supabase/migrations/      Reserved cloud path; no cloud schema yet
├── compose.yaml              Includes the existing hub Docker Compose service
├── watch/   Flutter app (Wear OS): Vosk STT → triage_parser.dart → sqflite → HTTP send
├── hub/     Node + Express + SQLite: POST /api/sync-triage, ED pre-arrival board, Docker
└── fake-watch.sh   curl stand-in for a watch (demo backup / hub smoke test)
```

| Document | Responsibility |
| --- | --- |
| [Architecture](docs/architecture.md) | Source of truth: approved target versus actual code |
| [API contract](docs/api-contract.md) | Implemented LAN requests, responses and retry behavior |
| [Conventions](docs/conventions.md) / [AGENTS.md](AGENTS.md) | Contributor and agent guardrails |
| [Reverse-engineering report](docs/reverse-engineering.md) | Dated verification, evidence, gaps and next steps |
| [Migration layout](database/migrations/README.md) | Schema owners and safe upgrade requirements |
| [Developer Guide](docs/DEVELOPER_GUIDE.md) | Detailed prototype feature reference; historical claims are labeled |

## What one spoken sentence produces

> *"Dalawang bata, nalunod at walang malay, sa Barangay Arnaldo, sampung minuto papunta sa ospital."*

| Field | Value |
|---|---|
| Triage (START) | **Immediate** (red) |
| Patients / age | ×2 · Child |
| Findings | Drowning, Unconscious |
| Pickup | Barangay Arnaldo |
| ETA | 10 min |

The hospital board turns findings into a **"Prepare for"** list (airway + warming, neuro
obs, paediatrics, blood/OR, OB, antivenom, X-ray…) and totals patients per category, so
the ED can open a resus bay *before* the boat docks.

## Triage logic (`watch/lib/nlp/triage_parser.dart`)

START-style categories, **worst finding wins** (over-triage is the safe direction):

| Category | Triggers (Tagalog + English, fuzzy-matched) |
|---|---|
| **Immediate** (red) | not breathing, difficulty breathing, drowning, unconscious, severe bleeding, head injury, chest pain, electrocution, pregnant/labor |
| **Delayed** (yellow) | fracture, laceration/wound, bleeding, hypothermia, burn, snakebite, weak/dehydrated, *cannot walk* |
| **Minor** (green) | abrasion/minor, *can walk* |
| **Deceased** (grey) | only when nothing else is found, so it never hides a live patient |
| **Unassessed** | speech saved but no medical keyword understood; the hub ranks it right after Immediate, since unknown could be critical |

Also extracted: patient count ("dalawang bata", "3 patients"), age group (infant / child /
elderly), pickup barangay, ETA ("sampung minuto", "15 minutes", "kalahating oras").
Specific findings hide generic ones ("malakas na pagdurugo" doesn't also list "bleeding").
Fuzzy matching only applies to words of 7+ letters, because short Tagalog words differ by
one letter from unrelated ones (*nabali* fractured vs *nabalik* returned).

**This is decision support, not diagnosis.** Rescuers speak, a keyword matcher
interprets; the ED must confirm every patient on arrival. One report = one group of
patients in one category: a mixed group ("one critical, two minor") should be spoken as
separate reports. Pickup locations are the four barangays in the `locations` map; edit it
for your area.

## Watch behaviour

- Single tap = start/stop dictation (big high-contrast button, glove-friendly).
- Live transcript scrolls as you speak. Stopping parses, saves to `triage_logs`
  (`sync_status = false`), and shows the parsed card.
- **Haptics:** saved = 2 short · **Immediate = 3 long** · heard-but-not-understood = 4 rapid · silence = 1 long.
- **SEND TO HOSPITAL** pushes the unsent queue; a report is only marked sent when the hub
  acknowledges it. Safe to tap repeatedly.
- Long-press the `W-XXXX · N PENDING` header to run a sample report with no microphone
  (demo fail-safe).

## Hospital hub

- `POST /api/sync-triage` accepts `{ watchId, reports: [...] }`.
- **Duplicate protection:** unique on `(watch_id, created_at)`. A re-sent batch is skipped
  but still acknowledged, so a double sync can't make the ED prepare for patients who don't exist.
- Board: live updates (SSE), sorted Immediate → Unassessed → Delayed → Minor → Deceased,
  then soonest ETA; countdowns per patient; "Arrived" / "Cancel" actions; surge tiles; no
  CDN dependencies.
- Set the hospital name: `HOSPITAL_NAME="Santiago District Hospital · ED"` (env var).

```bash
# From the repository root; Docker Compose >= 2.20.3
cp .env.example .env             # defaults to localhost access
docker compose config --quiet
docker compose up --build        # build while online; runtime needs no internet
# For a LAN demo, set HUB_BIND_ADDRESS to the laptop LAN IP in .env, then recreate.
# Without .env, existing all-interface binding on port 3000 is retained.
# Stop with docker compose down; never delete data to resolve a startup problem.

# Or native Node, from the repository root:
cd hub
npm ci
npm test                         # 7 tests, in-memory databases
node --env-file=../.env server.js # .env must exist; npm start uses defaults/shell env
# Separate terminal, repository root, against a disposable synthetic demo database:
./fake-watch.sh http://localhost:3000
```

Board: `http://<laptop-lan-ip>:3000` (the hub prints its LAN IPs on start).
Requires Node 22+ (`better-sqlite3` 13); locally checked with Node 24.20.0,
Docker uses Node 22. Docker installs the committed lockfile with `npm ci`.
The API and dashboard run in one container; there is no React build/service.
Root Compose and `cd hub && docker compose up --build` both use `hub/data`.
Use one entry point at a time; project names differ, but data and ports are shared.
To load root configuration with the legacy entry point, use
`cd hub && docker compose --env-file ../.env up --build`.
Do not use `fake-watch.sh` against a database containing real reports.

Configuration: `.env.example` documents `HOSPITAL_NAME`, `HUB_PORT` and
`HUB_BIND_ADDRESS` for Compose; native Node uses `PORT`, `DB_PATH` and
`HOSPITAL_NAME` and does not auto-load `.env`. Inside Docker, port 3000 and
`/data/vanguard.db` remain fixed. `HUB_URL` and `VOSK_MODEL` are watch compile-time
defines; `.env` does not automatically configure Flutter.

## Watch app

```bash
cd watch
flutter pub get --enforce-lockfile
flutter analyze
flutter test                     # 12 parser tests
flutter run --dart-define=HUB_URL=http://192.168.8.10:3000
```

The app requires Dart >= 3.13.2 and < 4; CI pins the locally checked Flutter 3.47.5
(Dart 3.13.4). An Android SDK is required to build/install. Provision the speech
asset **before** running the app; missing assets cause `MODEL ERROR` and disable
normal recording and the header demo flow. Android SDK is absent on the audited Mac.

Give the hub laptop a DHCP reservation on the router so `HUB_URL` never changes. Android
config already includes mic/internet/vibrate permissions, cleartext HTTP (the LAN has no
TLS), the Wear OS watch flag, and `minSdk 26`.

### Speech models

`watch/assets/models/` contains only `.gitkeep`. Download the chosen model ZIP
separately and keep it uncommitted. The default code path is
`assets/models/vosk-model-small-en-us-0.15.zip`. The
[Vosk catalogue](https://alphacephei.com/vosk/models) lists this English model as
40M and `vosk-model-tl-ph-generic-0.6` as 320M (no small Filipino model listed).
To choose the latter, place the ZIP in that folder and pass
`--dart-define=VOSK_MODEL=assets/models/vosk-model-tl-ph-generic-0.6.zip`.
Language accuracy, model loading, memory and battery use remain unverified on the
watch. A companion phone is a target fallback requiring implementation/testing.

## Demo script

1. **Offline:** disable Wi-Fi/data on the laptop and the watch (start the hub first).
2. **Edge compute:** tap, say the sentence above, tap again. 3 long buzzes; the watch shows
   `IMMEDIATE ×2 · Child · Drowning, Unconscious · ETA 10 min`.
3. **Reconnect:** power the router; join the watch and laptop to it.
4. **Handoff:** tap **SEND TO HOSPITAL**. The red card appears on the ED board, "Prepare for"
   updates, and the 10-minute countdown starts.
5. **Resilience:** tap send again: no duplicate.

## Known limits

- Current verification and gaps are recorded in the dated
  [reverse-engineering report](docs/reverse-engineering.md). Historical browser/mock
  claims in the old guide do not establish native watch behavior.
- There are no structured patient-name fields, but transcripts can contain names
  or other identifying information. HTTP has no auth/TLS and SQLite is unencrypted.
  Use synthetic development data; access controls and protected storage/transport
  are required before real patient use.
- Watch sync sends the entire queue; the hub rejects over 500 reports or over 1 MB.
  No automatic batching, background sync, cloud or BLE exists.
- A four-hex-digit watch ID and process-local timestamp ordering can collide across
  devices/restarts/clock rollback. Returned ACK IDs are not authenticated/scoped.
- No migrations are applied by this foundation; current schemas are unchanged.
- Air-gapped devices have no NTP: ETA countdowns depend on the watch clock and are approximate.
- This is a hackathon prototype, not a validated clinical triage tool.

CI runs hub tests, watch analysis/parser tests, shell/JS syntax checks and Compose
build/container tests. Native builds and device acceptance are not CI checks yet.
Use feature branches and reviewed PRs; repository administrators must separately
configure branch protection for the named checks. `AGENTS.md` is guidance, not a
technical enforcement mechanism.
