# Vanguard-Wrist (MVP): offline medical triage → hospital pre-arrival

A rescuer taps a Wear OS watch and describes the patient(s) out loud. The watch
transcribes **on-device** (Vosk), extracts a structured medical triage report with a
deterministic Taglish keyword pipeline, queues it in SQLite, and, once it reaches an
internet-free Wi-Fi router, sends it to a Dockerized hospital hub. The ED sees a
live pre-arrival board: how many casualties are coming, how bad, what they need, and
when they arrive.

```
vanguard-wrist/
├── docs/    Developer guide: architecture, API, data model, extending, troubleshooting
├── watch/   Flutter app (Wear OS): Vosk STT → triage_parser.dart → sqflite → HTTP send
├── hub/     Node + Express + SQLite: POST /api/sync-triage, ED pre-arrival board, Docker
└── fake-watch.sh   curl stand-in for a watch (demo backup / hub smoke test)
```

> **Developers:** see the full [Developer Guide](docs/DEVELOPER_GUIDE.md).

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
cd hub
docker compose up --build        # build once WHILE ONLINE; runs offline afterwards
# or:  npm install && npm start
npm test                         # 7 tests
../fake-watch.sh                 # sends a sample Immediate report (run twice quickly → duplicate)
```

Board: `http://<laptop-lan-ip>:3000` (the hub prints its LAN IPs on start).
Requires Node 22+ (`better-sqlite3` 13).

## Watch app

```bash
cd watch
flutter pub get
flutter test                     # 12 parser tests
flutter run --dart-define=HUB_URL=http://192.168.8.10:3000
```

Give the hub laptop a DHCP reservation on the router so `HUB_URL` never changes. Android
config already includes mic/internet/vibrate permissions, cleartext HTTP (the LAN has no
TLS), the Wear OS watch flag, and `minSdk 26`.

### ⚠ The Tagalog speech model

There is **no Vosk Tagalog model under 50 MB**. Vosk publishes `vosk-model-small-en-us-0.15`
(41 MB) and `vosk-model-tl-ph-generic-0.6` (**~329 MB**). The default is the small English
model, which hears English terms (drowning, fracture, unconscious) but will mangle Tagalog.
For real Taglish use the 329 MB model: put its zip in `watch/assets/models/` and run with
`--dart-define=VOSK_MODEL=assets/models/vosk-model-tl-ph-generic-0.6.zip`. Test on the real
watch early: RAM may not allow it. Fallback: run the same app on a phone.
Models: <https://alphacephei.com/vosk/models>.

## Demo script

1. **Offline:** disable Wi-Fi/data on the laptop and the watch (start the hub first).
2. **Edge compute:** tap, say the sentence above, tap again. 3 long buzzes; the watch shows
   `IMMEDIATE ×2 · Child · Drowning, Unconscious · ETA 10 min`.
3. **Reconnect:** power the router; join the watch and laptop to it.
4. **Handoff:** tap **SEND TO HOSPITAL**. The red card appears on the ED board, "Prepare for"
   updates, and the 10-minute countdown starts.
5. **Resilience:** tap send again: no duplicate.

## Known limits

- **Verified so far:** `flutter analyze` clean; 12 parser tests; 7 hub tests; the hub run for
  real and its board exercised in a browser; and the watch UI flow (dictate → parse → save →
  send → appears on the hub) run through a **web preview with stand-ins for Vosk and SQLite**.
  **Not run:** Vosk, sqflite, haptics, the Android/Wear OS build, or the Docker image: they need
  an Android SDK/device and Docker, which weren't available.
- **No patient identity** is collected (no names), but reports travel over unauthenticated
  HTTP on a closed LAN. Fine for a sealed router; add auth/TLS before any real use.
- Air-gapped devices have no NTP: ETA countdowns depend on the watch clock and are approximate.
- This is a hackathon prototype, not a validated clinical triage tool.
