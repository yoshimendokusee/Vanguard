# WristCue: offline medical triage → hospital pre-arrival

A rescuer taps a Wear OS watch and describes the patient(s) out loud. The watch
transcribes **on-device** (Vosk), extracts a structured medical triage report with a
deterministic Taglish keyword pipeline, queues it in SQLite, and, once it reaches an
internet-free Wi-Fi router, sends it to a Dockerized hospital hub. The ED sees a
live pre-arrival board: how many casualties are coming, how bad, what they need, and
when they arrive. This describes the implemented prototype, not hardware-verified
operation or clinical validation. No speech model is bundled in this checkout.

The repository now includes local Qwen3-0.6B GGUF weights through Git LFS,
Ollama inference in the existing hospital hub, and native SwiftUI iOS/watchOS app
targets with CPU llama.cpp and durable local processing. Both Apple simulators have
generated real tokens; physical-device feasibility, offline Watch speech and
paired-device transfer remain unverified. See [Qwen integration](docs/QWEN_INTEGRATION.md)
and [performed results](docs/QWEN_RESULTS.md). The existing Flutter/Wear OS app,
SQLite/hospital flows and optional Supabase path remain in place. BLE, Realtime
and the proposed React replacement are still target work.

```
vanguard-wrist/
├── AGENTS.md                 AI agent guardrails
├── docs/                     Architecture, actual API, conventions, audit, legacy guide
├── .github/                  PR/issue templates and CI
├── database/migrations/      Migration ownership and upgrade guide
├── supabase/migrations/      PostgreSQL report table and RLS migration
├── compose.yaml              Includes the existing hub Docker Compose service
├── watch/   Flutter app (Wear OS): Vosk STT → triage_parser.dart → sqflite → HTTP send
├── hub/     Node + Express + SQLite migrations: POST /api/sync-triage, ED board, Docker
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
  and shows the parsed card. Local save does not depend on a network.
- **Haptics:** saved = 2 short · **Immediate = 3 long** · heard-but-not-understood = 4 rapid · silence = 1 long.
- Reports automatically attempt sync after SQLite save, at startup/resume and on foreground retries. **RETRY NOW** is optional; only validated ACKs for transmitted rows mark them synced.
- **ONLINE** separately upserts reports for the signed-in Supabase user. Failed/offline
  uploads remain pending and can be retried. Cloud account and report ownership are separate
  from the hospital sync status.
- Long-press the `W-XXXX · N PENDING` header to run a sample report with no microphone
  (demo fail-safe).

## Hospital hub

- `POST /api/sync-triage` accepts `{ watchId, reports: [...] }`.
- **Duplicate protection:** unique on `(watch_id, created_at)`. A re-sent batch is skipped
  but still acknowledged, so a double sync can't make the ED prepare for patients who don't exist.
- Board (teal dashboard): a rail with status tabs (On the way, Arrived, Cancelled, All reports); the "Priority patient" card with a countdown,
  a readiness checklist and **Mark arrived**; "Due within 30 minutes" and "Teams to alert"; a category filter, "Coming up" cards and an
  arrivals curve; the patient list sorted Immediate → Unassessed → Delayed → Minor → Deceased, then soonest ETA. Live updates (SSE),
  light/dark/auto theme, no CDN dependencies.
- Set the hospital name: `HOSPITAL_NAME="Santiago District Hospital · ED"` (env var).

## Run the Docker web app

Install Git and Docker Desktop (or Docker Engine with Compose **2.20.3+**).
Clone normally. A one-shot model initializer copies verified checkout weights or
downloads the pinned GGUF when the checkout contains only an LFS pointer. No host
Ollama or Git LFS installation is required for Docker startup.
No host Node.js, npm, Vite or backend libraries are needed. From the repository root:

```sh
docker compose down --remove-orphans
docker compose -f hub/docker-compose.yml down --remove-orphans
docker compose up -d --build --force-recreate --remove-orphans
# Open http://localhost:3000/

docker compose ps
docker compose logs -f model-init hub ollama
docker compose down           # preserves hub/data and model volumes
```

The root Docker Compose entry point builds the latest `hub/public` assets into the
production image and serves them from Express at **localhost:3000**. Port 3000 is
the only published host port; Ollama stays on its internal network. Rebuild and
recreate the container after web app edits with `docker compose up -d --build
--force-recreate --remove-orphans`. The default Docker app does not use a host
Node.js, npm or Vite server.

The first two `down` commands stop the root stack and the legacy `hub/` stack before
the update, releasing their old port mappings. They remove containers and networks
only; they preserve `hub/data` and named model volumes. Do not run both entry points
at once, and never use `down -v` or reset SQLite as a startup fix. If port 3000 is
still occupied, inspect `docker ps --filter publish=3000` and stop the identified
conflicting stack before starting Vanguard.

The initial image/model pull needs internet. After provisioning, prepared images,
dependencies and model weights run locally; report capture and the board do not
require cloud access. The app remains usable if local AI is unavailable.

Common fixes:

- **Port 3000 already allocated:** run the two `docker compose down --remove-orphans`
  commands above. If the port remains occupied, inspect `docker ps --filter
  publish=3000` and stop the identified conflicting stack before starting Vanguard.
- **Old UI after an edit:** rebuild and recreate the Docker hub with
  `docker compose up -d --build --force-recreate --remove-orphans`, then reload
  localhost:3000.
- **API unavailable:** check hub health/logs and the configured data-directory
  permissions. Retain data and fix the cause; don't replace the database.
- **AI unavailable:** inspect `model-init` and Ollama logs; first-time provisioning
  needs internet and disk space. Retry Compose after correcting a download failure.
  `AI Live` requires real completed tokens, not just a model tag. The board/intake
  remain usable without AI.

For synthetic LAN testing, configure per-user/device `HUB_USERS` credentials and
set `HUB_BIND_ADDRESS` to the host's LAN interface in `.env`, then recreate the hub.
The native app accepts a saved hospital URL such as `http://<hub-hostname>.local:3000`
and an assigned token stored in Keychain. It rejects device localhost and malformed
origins. Local AI readiness is independent of LAN status. There is no reliable Docker
multicast discovery here; use the host's LAN hostname/address or a DHCP reservation
and update the saved URL when the network changes. Legacy Flutter uses explicit
`HUB_URL` and `HUB_TOKEN` build settings; its former fixed private-IP default is removed.
Use Settings in the web board to connect with an operator token. LAN credentials do
not encrypt HTTP or storage: use synthetic data on isolated networks until protected
transport/storage and clinical validation exist. See [global connectivity setup and
verification](docs/global-ai-connectivity.md).

To build the hub address into the Apple apps instead of typing it on each device,
copy `watch/apple/Config/Secrets.xcconfig.example` to `Secrets.xcconfig` (git-ignored)
and set `HUB_URL = http:/$()/<computer-lan-ip>:3000`. The `$()` is needed because
`//` starts an xcconfig comment. The project's base configuration is
`Config/Vanguard.xcconfig`, and `Config/Info.plist` passes the value to
`AppConfiguration.load()`. A saved in-app URL still takes precedence. Optional
`SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` stay empty when the hub uploads to Supabase.
Info.plist is readable from the installed app, so it holds public values only:
never the hub password, `sb_secret_*` or service-role keys. Values are fixed at build
time; rebuild after changing them. See [Apple hub URL verification](docs/apple-hub-url-verification.md)
for the earlier unsigned simulator checks. [Shared hub setup](docs/shared-hub-setup.md)
records the current Wi-Fi hostname, per-device enrollment and signed simulator checks.

Optional native hub development (Node 22.12+):

```sh
cd hub
npm ci
npm test
npm start
# npm run build creates optimized dist assets for Express.
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

## Sample data for a busy board

`hub/seed.js` loads one synthetic typhoon-shift scenario into a running hub: 24
reports from four rescue teams (42 patients, one report with no stated count),
spread from arriving now to later than an hour, plus four arrivals, two
cancellations, a clinical override and a corrected transcript. It posts the same
LAN batches a watch posts and then uses the same dashboard endpoints an operator
uses, so the hub's validation, duplicate protection, provisional assessment and
clinical history all behave as they do in a live demo. It never edits the
database file directly. Synthetic patients only: never point it at a hub holding
real reports. Restart the hub (or its container) afterwards to clear it; the QA
hospital is disposable.

```bash
cd hub
node seed.js                               # hub on http://127.0.0.1:3000
node seed.js --url http://127.0.0.1:3301   # the isolated QA hospital
node seed.js --dry-run                     # validate the scenario, send nothing
node seed.js --force                       # load another wave on purpose
```

The scenario is plain data at the top of `hub/seed.js`: edit the places, findings,
counts and arrival times to match your own barangays.

Configuration: `.env.example` documents `HOSPITAL_NAME` and
`HUB_BIND_ADDRESS` for Compose; native Node uses `PORT`, `DB_PATH` and
`HOSPITAL_NAME` and does not auto-load `.env`. Inside Docker, port 3000 and
`/data/vanguard.db` remain fixed. `HUB_URL`, `VOSK_MODEL`, `SUPABASE_URL` and
`SUPABASE_ANON_KEY` are watch compile-time defines; `.env` does not automatically
configure Flutter.
Configuration: `.env.example` documents Compose host binding, hospital label and
watch build settings. Docker publishes the hub on fixed port 3000 and uses
`/data/vanguard.db`.
Watch build-time settings are independent; root `.env` does not configure Flutter
or Apple devices automatically. Do not run `fake-watch.sh` against existing reports.

### Supabase cloud backup (hub)

The hub is the only component that needs Supabase settings. Watch, iPhone and
dashboard clients talk to the hub over the LAN. The hub uploads to Supabase
whenever it has internet. `.env` is git-ignored, but the hub reads it from disk on
the hospital computer, so it connects without the file being in Git.

1. In Supabase: apply `supabase/migrations/` (see its README), then go to
   **Authentication → Users → Add user** and create a dedicated hub account
   (email + password, auto-confirm).
2. In the root `.env` (copy `.env.example`): set `SUPABASE_URL`,
   `SUPABASE_ANON_KEY` (publishable key), `SUPABASE_HUB_EMAIL` and
   `SUPABASE_HUB_PASSWORD`. Never use a secret/service-role key. Quote values
   that contain `$` or `#` in single quotes.
3. Start the hub: `docker compose up --build` from the root, or natively
   `cd hub && node --env-file=../.env server.js`. The board header shows
   `Cloud synced`, `Cloud · N queued`, `Cloud offline` or `Cloud off`, plus a
   **Sync to cloud** button.

Reports always save to hub SQLite first. Offline, they stay queued and upload
automatically once online. Leaving any value empty keeps the hub LAN-only. Use
synthetic data only: the LAN API and SQLite are unauthenticated and unencrypted.

## Local Qwen inference

Pinned Q4_K_M weights are defined by `models/qwen3-0.6b/manifest.json`. Docker's
first run provisions these weights into `qwen-weights`, verifies their checksum and
imports them into the separate persistent `ollama-models` volume. Initial setup needs
internet when weights/images are missing. Later runtime container recreation uses
these volumes; Ollama has no external network route. Never delete model volumes as
a recovery step.

```sh
# Web: no host Ollama required
docker compose up -d --build
# Apple: model packaging needs Node 22+, Xcode SDKs and CMake; no Docker/Ollama
./scripts/qwen-setup.sh --model-only
./scripts/qwen-native-build.sh
open watch/apple/Vanguard.xcodeproj
# Optional host Ollama development only: start Ollama 0.11.4 separately
./scripts/qwen-setup.sh host
./scripts/qwen-echo.sh
# Synthetic fresh-clone, real inference and recovery acceptance
node scripts/connectivity-check.cjs
```

Both Compose entry points preserve `hub/data`. The browser's central client uses
same-origin `/api/*`, saves each original to an account-scoped local outbox before
inference and automatically transmits provisional reports. Failed extraction can
transmit an Unassessed original. Only a scoped hospital ACK removes a local outbox
item. Persisted **Evidence and corrections** extraction appends an immutable revision
without overwriting the original. `/api/ai/health` and `/api/ai/status` require actual
generation; model presence alone is insufficient. `AI_NUM_THREADS` defaults to two,
with a bounded Ollama queue; capacity and inference latency depend on the host.

Qwen does not recognize speech or independently assign urgency. Machine claims
remain unverified; unknown data never means normal. Apple typed capture uses native
inference; iPhone speech uses the existing on-device transcriber. Watch audio is
saved and queued for iPhone processing because offline Watch STT is unimplemented.

Read [complete setup, scripts, measurements and blockers](docs/QWEN_INTEGRATION.md)
and [the AI API contract](docs/ai-contract.md). Keep synthetic development on isolated
networks: existing LAN/storage protections remain prototype limitations.

## Watch app

```bash
cd watch
flutter pub get
flutter analyze
flutter test                     # parser, database migration and cloud payload tests
flutter run \
  --dart-define=HUB_URL=http://192.168.8.10:3000 \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<publishable-or-anon-key>
```

Create a Supabase project, then apply the checked-in migration as described in
[supabase/migrations/README.md](supabase/migrations/README.md). Enable the email
provider in Supabase Auth. The app supports email/password sign-in and sign-up;
email confirmation may be required by the project's Auth settings. Use only the
publishable/anon key in Flutter. Do not pass a service-role key to `--dart-define`.
The Supabase button syncs automatically after local saves made while signed in,
on app startup when a session exists, and when tapped. It does not run a
background connectivity watcher.

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
4. **Handoff:** foreground retry sends automatically (or tap **RETRY NOW**). The red card appears on the ED board, "Prepare for"
   updates, and the 10-minute countdown starts.
5. **Resilience:** tap send again: no duplicate.

## Known limits

- Current verification and gaps are recorded in the dated
  [reverse-engineering report](docs/reverse-engineering.md). Historical browser/mock
  claims in the old guide do not establish native watch behavior.
- The hub now supports explicit patient identity revisions; transcripts can also contain names
  or other identifying information. HTTP has no auth/TLS and SQLite is unencrypted.
  Use synthetic development data; access controls and protected storage/transport
  are required before real patient use.
- Watch sync batches at 100 rows, with bounded bodies and foreground retry/backoff.
  Background LAN delivery and BLE remain unimplemented; transcripts up to 16,000 characters use bounded byte-aware batches.
- A four-hex-digit watch ID can collide across devices; timestamps now advance from
  the persisted maximum inside the SQLite transaction after restart/clock rollback. Returned ACK IDs are scoped to sent rows but remain unauthenticated.
- Watch v2 and hub baseline migrations upgrade SQLite in place; Supabase migration application is separate.
- Air-gapped devices have no NTP: ETA countdowns depend on the watch clock and are approximate.
- This is a hackathon prototype, not a validated clinical triage tool.

The supported product targets are Apple Watch, iPhone and the hospital web app.
The Flutter watch code remains a legacy Wear OS prototype; native Apple app targets and shared modules are under `watch/apple`. CI runs hub/API/dashboard tests, existing Dart analysis/parser regressions,
formatting, secret scanning, workflow/configuration validation and Docker tests.
There is no Android build or Apple native/hardware validation in this workflow.
See [the team workflow](docs/GITHUB_WORKFLOW.md) and
[the main protection policy](.github/branch-policy.md) for the six required checks,
review requirements and verified GitHub settings. The new workflow still needs
to be committed, pushed and integrated. `AGENTS.md` is guidance, not enforcement.


Current delivery and teammate instructions:
[implementation report](docs/implementation-report.md),
[Qwen agent handoff](docs/qwen-agent-handoff.md),
[database handoff](docs/database-team-handoff.md), and
[Windows hospital QA](docs/windows-qa.md).
For an isolated synthetic QA hospital use `hub/compose.qa.yaml` (localhost:3301);
normal root and legacy Compose data paths remain unchanged.
- Cloud reports captured while signed out or before v2 require explicit owner assignment before upload.


## Backend integration

Hub SQLite v2 persists original evidence, structured findings/provenance,
patient/encounter revisions, provisional assessment history, corrections and
operator overrides. The existing dashboard exposes Evidence and corrections;
automatic LAN submission still follows local save without a manual gate.
Read [the API contract](docs/api-contract.md) and
[backend completion report](docs/backend-completion.md) for the schema, audited
execution paths, performed checks and limitations. That earlier backend phase introduced no native Apple app/model runtime; the later Qwen integration adds those paths as documented above. Use synthetic isolated development only.
