# WristCue: offline medical triage → hospital pre-arrival

A rescuer taps a Wear OS watch and describes the patient(s) out loud. The watch
transcribes **on-device** (Vosk), extracts a structured medical triage report with a
deterministic Taglish keyword pipeline, queues it in SQLite, and, once it reaches an
internet-free Wi-Fi router, sends it to a Dockerized hospital hub. The ED sees a
live pre-arrival board: how many casualties are coming, how bad, what they need, and
when they arrive. This describes the implemented prototype, not hardware-verified
operation or clinical validation. No speech model is bundled in this checkout.

The approved target adds mobile BLE relay, Supabase sync, local LLM extraction and
a React/TypeScript/Tailwind dashboard. On-device Qwen weights/runtime and durable processing storage belong to teammates and are **not implemented**. This branch adds automatic foreground sync, hospital provisional rules, native iPhone STT/recovery library ports and Windows QA; complete Apple apps remain blocked.
The existing watch, hub and plain HTML dashboard remain in their current paths.
Optional authenticated Supabase sync coexists with automatic foreground LAN sync.
Main adds hospital provisional rules, native iPhone STT/recovery library ports and
Windows QA; Backend adds SQLite migrations and cloud sync. Local LLM extraction,
BLE, Realtime and complete Apple apps remain unimplemented. Applications stay in place.

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

```bash
# From the repository root; Docker Compose >= 2.20.3
cp .env.example .env             # defaults to localhost access
docker compose config --quiet
docker compose up --build        # build while online; runtime needs no internet
# For a LAN demo, set HUB_BIND_ADDRESS to the laptop LAN IP in .env, then recreate.
# Without .env, existing all-interface binding on port 3000 is retained.
# Stop with docker compose down; never delete data to resolve a startup problem.

<<<<<<< Updated upstream
# Or native Node, from the repository root:
=======
Install Git and Docker Desktop (or Docker Engine with Compose **2.20.3+**).
Clone with the repository's Git LFS model weights available; a pointer-only clone
still runs the board/API but cannot start Qwen. See the model checkout steps below.
No host Node.js, npm, Vite or backend libraries are needed. From the repository root:

```sh
docker compose up -d --build   # first run; installs locked dependencies in Docker
# Open http://localhost:3301/
docker compose up -d           # subsequent runs; no rebuild

docker compose ps
docker compose logs -f frontend hub ollama
docker compose down           # preserves hub/data and model volumes
```

Every teammate runs an independent copy at the same localhost URL. Exchange code
through Git commits/pulls; Vite updates only the files edited on your own computer.
The initial build/image pull needs internet. Prepared images, dependencies and
model weights run locally afterward; no cloud service is required for report capture.

Edit `hub/public/index.html`, `dashboard.css`, `dashboard.js` and frontend assets
with your editor. Root Compose adds a Vite frontend on **localhost:3301** to the
existing Express/SQLite hub (**localhost:3000**) and internal Ollama service
(**11434**, no host port). `/api` requests, including SSE, proxy to `http://hub:3000`
through Docker DNS. The browser and HMR WebSocket use port 3301; Vite listens on
`0.0.0.0:3301` inside its container with a strict port. The frontend waits for the
hub health check; capture/board startup does not wait for optional AI readiness.

The plain JavaScript dashboard keeps its existing framework and business logic.
CSS updates apply in place and preserve browser state. JavaScript/HTML edits
reload automatically; URL/localStorage state survives, unsaved forms can be lost.
Read-only source bind mounts expose host edits; dependencies stay in the image,
so host `node_modules` cannot shadow them. Docker Desktop polling defaults to
250 ms for reliable Windows/macOS bind mounts. Native Linux or WSL projects kept
inside the Linux filesystem can set `VITE_USE_POLLING=false` in root `.env` when
file events work. Copying `.env.example` is optional; Compose has working defaults.

Rebuild with `docker compose up -d --build` after dependency, Dockerfile or backend
changes. Vite config changes restart Vite automatically; Compose environment or
mount changes need `docker compose up -d`. UI source edits need neither command.
For frozen optimized assets served by Express (no Vite development server):

```sh
docker compose down
docker compose -f hub/docker-compose.yml up -d --build
# Open http://localhost:3000/
docker compose -f hub/docker-compose.yml down
# Equivalent legacy entry point: cd hub && docker compose up -d --build
```

The multi-stage Dockerfile runs `npm ci` and `npm run build`, then keeps production
libraries and `dist` in the final image without Vite or compiler tools. Express uses
`dist` when built, otherwise native `npm start` retains the source dashboard.
Root development and legacy production both retain **hub/data:/data** and
`/data/vanguard.db`; run one stack at a time. `down` keeps storage. Never delete
`hub/data`, reset SQLite or use `down -v` as a startup fix. Synthetic QA can use
`hub/compose.qa.yaml` with its separate named volume; stop it before using port 3301.

Common fixes:

- **Port already allocated:** stop the other stack owning 3301 or 3000. `HUB_PORT`
  can change the backend host port without changing Docker API discovery or Vite.
- **No live update:** check `docker compose logs -f frontend`, Docker Desktop file
  sharing, and `VITE_USE_POLLING=true`. The browser should show `[vite] connected`.
  A dependency change needs a rebuild; ordinary source changes do not.
- **API unavailable:** check hub health/logs and the configured data-directory
  permissions. Retain data and fix the cause; don't replace the database.
- **AI unavailable:** ensure the actual pinned GGUF is checked out, not a Git LFS
  pointer, and check Ollama logs. The board/intake remain usable without AI.

For synthetic physical Apple Watch/iPhone testing, set `HUB_BIND_ADDRESS` to the
computer's isolated LAN IP in `.env` and recreate the hub. Configure the native
client with `http://<computer-lan-ip>:3000` (or `HUB_PORT`); device localhost points
to the device itself. Keep Vite bound to host localhost. API routes/ACK semantics
and native clients are unchanged. HTTP/storage remain unauthenticated/unencrypted;
use synthetic data on isolated networks. Native Apple apps still require Xcode
outside Docker. See [performed Docker checks and limits](docs/docker-development.md).

To build the hub address into the Apple apps instead of typing it on each device,
copy `watch/apple/Config/Secrets.xcconfig.example` to `Secrets.xcconfig` (git-ignored)
and set `HUB_URL = http:/$()/<computer-lan-ip>:3000`. The `$()` is needed because
`//` starts an xcconfig comment. The project's base configuration is
`Config/Vanguard.xcconfig`, and `Config/Info.plist` passes the value to
`AppConfiguration.load()`. A URL typed in the app still takes precedence. Optional
`SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` stay empty when the hub uploads to Supabase.
Info.plist is readable from the installed app, so it holds public values only:
never the hub password, `sb_secret_*` or service-role keys. Values are fixed at build
time; rebuild after changing them.

Optional native hub development (Node 22.12+):

```sh
>>>>>>> Stashed changes
cd hub
npm ci
npm test                         # synthetic in-memory/temporary databases
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
`/data/vanguard.db` remain fixed. `HUB_URL`, `VOSK_MODEL`, `SUPABASE_URL` and
`SUPABASE_ANON_KEY` are watch compile-time defines; `.env` does not automatically
configure Flutter.

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

## Local AI (Qwen via Ollama, hub-local)

Qwen `qwen3:0.6b` runs on the hospital computer through Ollama. The hub calls it
from `hub/ai.js` (`GET /api/ai/status`, `POST /api/ai/extract`,
`POST /api/ai/triage-assist`). The model only extracts what the transcript states
with evidence; deterministic `hub/risk.js` rules plus your review decide the
provisional triage. Nothing is saved by the AI routes. See `docs/ai-contract.md`.
Use synthetic data only. Never expose Ollama to the internet.

From Windows PowerShell at the repository root:

```powershell
# 1. Start Ollama on the hub computer, then check the model.
ollama list
# Must show qwen3:0.6b. If missing: ollama pull qwen3:0.6b

# 2. Configure the hub.
Copy-Item .env.example .env
# .env already sets OLLAMA_URL=http://127.0.0.1:11434 and OLLAMA_MODEL=qwen3:0.6b.

# 3. Run the hub with Docker (uses hub/data), then open the board.
docker compose up --build
# Board: http://localhost:3000

# 4. In the "Local AI triage assistant" panel: type a transcript, choose
# Extract with Qwen or Triage assist, review evidence and warnings, correct the
# fields, tick the review box, then Save reviewed report.
# Header shows AI ready or AI unavailable. The board works either way.

# 5. Backend tests (Docker, in-memory DB, no demo data touched).
docker build -t vanguard-hub-ai ./hub
docker run --rm -e DB_PATH=:memory: vanguard-hub-ai npm test -- --test-name-pattern="AI"
```

Native Node (needs Node 22+ and build tools for better-sqlite3): `cd hub; npm ci; npm test`.
Watch AI client: `watch/lib/services/ai_service.dart` posts to `/api/ai/*` and fails
fast offline so capture stays in SQLite. Apple types: `watch/apple/.../AiContract.swift`.
`127.0.0.1` on a watch or phone means that device, not the hub PC. For real devices
use the hub laptop LAN IP as `HUB_URL`, keep phone and hub on the same router, and
allow the hub port in Windows Firewall. No on-device Qwen, BLE, Supabase, or React
is claimed in this branch.

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
The current watch code is a legacy Wear OS prototype; Complete Apple applications do not exist yet; native library modules are under `watch/apple`. CI runs hub/API/dashboard tests, existing Dart analysis/parser regressions,
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
execution paths, performed checks and limitations. No new dependencies or native
Apple apps/model runtime were introduced. Use synthetic isolated development only.
