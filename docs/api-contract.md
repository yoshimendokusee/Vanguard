# Implemented LAN API contract

Source: `hub/server.js`, `hub/sync.js`, `hub/db.js` and the callers in
`watch/lib/services/sync_service.dart`, `hub/public/index.html`, `fake-watch.sh`.
This is the existing unversioned HTTP API, not a proposed cloud or BLE API.
There is no authentication, TLS, authorization or pagination. Use synthetic
data in isolated development networks only.

## Endpoints

| Method/path | Success | Validation/behavior |
| --- | --- | --- |
| `GET /api/health` | `200 {"ok":true,"time":"<hub ISO UTC>"}` | Liveness; not a database durability/readiness guarantee. |
| `GET /api/config` | `200 {"hospital":"<configured name>"}` | `HOSPITAL_NAME` or the default receiving hospital label. |
| `POST /api/sync-triage` | See below | One SQLite ingest transaction; acknowledges accepted and duplicate reports. |
| `GET /api/triage` | `200 [<stored row>, ...]` | Includes all statuses; inbound first, then effective hospital priority (Immediate, Unassessed, Delayed, Minor, Deceased); known ETA before unknown, then expected arrival and creation time. Original `triage` is preserved. |
| `PATCH /api/triage/:id` | `200 {"ok":true}` | Body `{"status":"inbound|arrived|cancelled"}`. `400 {"ok":false,"error":"Bad status"}` or `404 {"ok":false,"error":"Not found"}`. No transition restrictions. |
| `GET /api/events` | `200 text/event-stream` | `retry: 2000`; named `triage` events with `{"inserted":n}` or `{"updated":id}`; comments every 20 seconds. Fetch the list on an event; no durable cursor/replay. |
| `GET /` | Dashboard HTML | Locally served assets; same-origin API/SSE calls. |

## Batch request

```json
{
  "watchId": "W-TEST",
  "reports": [{
    "localId": 1,
    "location": "Barangay Arnaldo",
    "injuries": "Drowning, Unconscious",
    "triage": "Immediate",
    "patientCount": 2,
    "ageGroup": "Child",
    "etaMinutes": 10,
    "rawText": "Synthetic demo transcript",
    "createdAt": "2026-10-09T06:00:00.123Z"
  }]
}
```

| Field | Current validator |
| --- | --- |
| `watchId` | Required nonblank string; trimmed and truncated to 64 characters. Self-declared, not authenticated. |
| `reports` | Required array; empty is accepted; maximum 500. |
| `localId` | Integer used for acknowledgment correlation. Missing/noninteger becomes `null` and is not acknowledged; the report may still be inserted. Positive/unique IDs are not enforced by the hub. |
| `createdAt` | Must be accepted by JavaScript `Date.parse`; normalized to ISO UTC. Clients send ISO UTC milliseconds. Current validator does not require a strict ISO string type. |
| `triage` | `Immediate`, `Unassessed`, `Delayed`, `Minor`, `Deceased`. |
| `patientCount` | Integer 1–99; absent defaults to 1. |
| `ageGroup` | `Infant`, `Child`, `Adult`, `Elderly`, `Unspecified`; absent defaults to `Unspecified`. |
| `etaMinutes` | Integer 1–720 or `null`; absent defaults to `null`. |
| `location`, `injuries` | Strings, nonempty after trimming; truncated to 200/300 characters. Injuries is a comma-separated string, not an array. |
| `rawText` | Optional string; preserved exactly up to 1000 characters, otherwise empty if not a string. Over-limit strings are rejected without ACK to retain the original locally. |

Extra fields are ignored except `processing`, which is explicitly rejected without ACK until the database teammate integrates its durable storage. See `qwen-agent-handoff.md` for the validated integration envelope; it is not yet live ingest capability. `400 {"ok":false,"error":"Expected { watchId, reports: [] }"}`
rejects an invalid batch envelope. `413 {"ok":false,"error":"Max 500 reports per batch"}`
rejects too many reports. Express also rejects malformed JSON (`400`) and bodies
above 1 MB (`413`); those parser errors do not have this API's JSON error shape.

## Batch response and retry semantics

```json
{
  "ok": true,
  "inserted": 1,
  "duplicates": 0,
  "rejected": [],
  "ackLocalIds": [1]
}
```

Bad report fields produce `rejected: [{"localId":7,"reason":"invalid triage category"}]`
within a `200` response; `ok: true` does not mean every row succeeded. Other current
reasons: `not an object`, `invalid createdAt`, `invalid patientCount`,
`invalid ageGroup`, `invalid etaMinutes`, `missing location/injuries`,
`rawText exceeds legacy storage; retain original locally`,
`processing storage not integrated; retain report locally`, and the identity conflict above.

The identity is `(trimmed/truncated watchId, normalized createdAt)`.
Replay inserts zero rows but returns the duplicate row's supplied `localId` in
`ackLocalIds`. Immutable normalized report fields are compared on a collision. Identical replays are acknowledged; different content returns `identity conflict: original report differs` without ACK and does not overwrite the original. A database
failure rolls back the transaction; it must not be treated as receipt.
The watch retains rows on a non-200, timeout or decoding/connection failure;
on 200 it validates the response shape and scopes ACK IDs to the transmitted batch before marking them synced. Contradictory ACK/rejection IDs and malformed responses retain the batch. It still does not independently authenticate the hub. The watch batches at 100 rows and caps encoded bodies at 900 KiB. Over-limit originals remain queued while shorter reports can proceed. Automatic foreground retries run after save, at startup/resume and every 30 seconds on success, with failure backoff of 60/120/240/480 seconds. A manual Retry Now is optional. Rejected rows remain pending and the UI reports an incomplete-sync error. These limitations are recorded in `architecture.md`.

## Stored dashboard rows

`GET /api/triage` returns SQLite column names:
`id`, `watch_id`, `location`, `injuries`, `triage`, `patient_count`, `age_group`,
`eta_minutes`, `raw_text`, `created_at`, `received_at`, `status`.
`id` is the hub's integer ID, distinct from the watch `localId`.
`created_at` is the watch clock; `received_at` is the hub clock.
ETA is minutes after creation, so delayed sync or clock skew affects the countdown.

`sync_status = 1` on the watch means acknowledgment by this LAN endpoint;
`status = arrived` is a separate operator action at the hub. Neither is a
cryptographically verified delivery receipt. Cloud and BLE schemas/endpoints
are not implemented; specify and test them before adding consumers.


## Hospital provisional priority (additive fields)

The original `triage` column remains the source category. `GET /api/triage` adds
`provisional_triage`, `effective_triage`, `risk_reason`, `rule_version` and
`requires_verification: true`; no schema change is applied. `riskForRow` computes
these fields on read. The live rule version is `legacy-findings-v1`.

Exact comma-separated structured findings determine the first matching rule:

| Priority | Findings |
| --- | --- |
| Immediate | Not breathing; Difficulty breathing; Drowning; Unconscious; Severe bleeding; Head injury; Chest pain; Electrocution; Pregnant / labor |
| Delayed | Fracture; Laceration; Bleeding; Wound; Hypothermia; Burn; Snakebite; Weak / dehydrated; Non-ambulatory |
| Minor | Abrasion; Ambulatory |
| Unassessed | No recognized finding; reported Deceased without qualified confirmation |

No natural-language substring matching is performed by the hub. These prototype
rules reuse legacy findings; they are provisional decision support, not a
validated clinical protocol. Worst matched finding wins; a higher source urgency
is retained in `effective_triage`, including source Unassessed above Delayed/Minor.
Automatic rules never declare Deceased. ETA sorting applies within each effective
priority, and non-inbound rows follow inbound rows. The dashboard uses effective
priority for counts/color/order while displaying source category, rule and original
text. Clinical correction/override audit APIs remain blocked on database integration;
status PATCH remains available. `assessRisk` and `validateProcessing` provide tested
structured integration utilities, not persisted structured processing yet.
