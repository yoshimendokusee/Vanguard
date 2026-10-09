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
| `GET /api/triage` | `200 [<stored row>, ...]` | Includes all statuses; inbound first, then Immediate, Unassessed, Delayed, Minor, Deceased; known ETA before unknown, then expected arrival and creation time. |
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
| `rawText` | Optional string; trimmed/truncated to 1000 characters, otherwise empty. |

Extra fields are ignored. `400 {"ok":false,"error":"Expected { watchId, reports: [] }"}`
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
`invalid ageGroup`, `invalid etaMinutes`, `missing location/injuries`.

The identity is `(trimmed/truncated watchId, normalized createdAt)`.
Replay inserts zero rows but returns the duplicate row's supplied `localId` in
`ackLocalIds`. Content is not compared or updated on a collision. A database
failure rolls back the transaction; it must not be treated as receipt.
The watch retains rows on a non-200, timeout or decoding/connection failure;
on 200 it marks the returned IDs synced, without independently authenticating
the hub or restricting IDs to that request. The watch currently has no batching
or detailed rejected-row UI. These limitations are recorded in `architecture.md`.

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
