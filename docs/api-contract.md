# Implemented LAN API contract

Source: `hub/server.js`, `hub/sync.js`, `hub/db.js` and the callers in
`watch/lib/services/sync_service.dart`, `hub/public/index.html`, `fake-watch.sh`.
This is the existing unversioned HTTP API, not a proposed cloud or BLE API.
Anonymous localhost demos remain compatible. Configured LAN mode requires bearer
credentials (`HUB_USERS`); devices can submit only assigned watch IDs and cannot read
hospital records. Operators share authorized hospital records. There is no TLS,
storage encryption or pagination. Use synthetic data on isolated networks only.

## Endpoints

| Method/path | Success | Validation/behavior |
| --- | --- | --- |
| `GET /api/health` | `200 {"ok":true,"time":"<hub ISO UTC>"}` | Liveness; not a database durability/readiness guarantee. |
| `GET /api/config` | `200 {"hospital":"<configured name>"}` | `HOSPITAL_NAME` or the default receiving hospital label. |
| `POST /api/sync-triage` | See below | One SQLite ingest transaction; acknowledges accepted and duplicate reports. |
| `GET /api/triage` | `200 [<stored row>, ...]` | Includes all statuses; inbound first, then effective hospital priority (Immediate, Unassessed, Delayed, Minor, Deceased); known ETA before unknown, then expected arrival and creation time. Original `triage` is preserved. |
| `PATCH /api/triage/:id` | `200 {"ok":true}` | Body `{"status":"inbound|arrived|cancelled"}`. `400 {"ok":false,"error":"Bad status"}` or `404 {"ok":false,"error":"Not found"}`. All three statuses remain reversible; each actual change is recorded atomically as a status event. Repeating the same status adds no event. |
| `GET /api/events` | `200 text/event-stream` | `retry: 2000`; named `triage` events with `{"inserted":n}` or `{"updated":id}`, and `cloud` events carrying the cloud status object below; comments every 20 seconds. Fetch the list on an event; no durable cursor/replay. |
| `GET /api/cloud/status` | `200 {"ok":true,"configured":bool,"state":"disabled|idle|syncing|ok|error","message":string|null,"pending":n,"synced":n,"rejected":n,"lastAttemptAt":iso|null,"lastSuccessAt":iso|null}` | Hub-to-Supabase backup state. Counts cover all hub reports. Never includes credentials, tokens or row content. |
| `POST /api/cloud/sync` | Same body as status, after the attempt | Optional body `{"retryRejected":true}` also retries rejected rows. Joins a running sync. With cloud disabled, returns `disabled` without network access. Unauthenticated, like the rest of this API. |
| `GET /` | Dashboard HTML | Locally served assets; same-origin API/SSE calls. |

Development dashboard access is `http://localhost:3301`; Vite proxies `/api`
unchanged to the Docker hub on port 3000, including SSE. Legacy/production Express
serves optimized dashboard assets when `dist` exists, otherwise source assets.
Native devices keep using the computer's isolated LAN API address/port; their own
localhost cannot reach the computer. No wire format or acknowledgment changes.

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
| `watchId` | Required nonblank string; trimmed, maximum 64 characters; longer values are rejected without truncation. Self-declared, not authenticated. |
| `reports` | Required array; empty is accepted; maximum 500. |
| `localId` | Positive safe integer if supplied. Missing IDs may be persisted but are not acknowledged. Repeated IDs within a batch reject every ambiguous row; no ambiguous acknowledgment is emitted. |
| `createdAt` | ISO timestamp string with seconds and explicit Z/offset, optional 1–6 fractional digits; impossible calendar dates are rejected. Normalized to UTC milliseconds for legacy identity. |
| `triage` | `Immediate`, `Unassessed`, `Delayed`, `Minor`, `Deceased`. |
| `patientCount` | Integer 1–99; absent/null retains legacy stored default 1, but `patient_count_known` is false and the submitted unknown is preserved. The dashboard excludes unknown counts from totals. |
| `ageGroup` | `Infant`, `Child`, `Adult`, `Elderly`, `Unspecified`; absent defaults to `Unspecified`. |
| `etaMinutes` | Integer 1–720 or `null`; absent defaults to `null`. |
| `location`, `injuries` | Nonblank strings up to 200/300 characters; over-limit values are rejected, not truncated. Injuries is a comma-separated string, not an array. |
| `rawText` | Optional string, preserved exactly up to 16,000 characters. Non-strings and over-limit strings are rejected without ACK. If processing is supplied, both original transcripts must match; absent rawText uses the processing original. |

Extra fields remain in the original submission snapshot but do not drive clinical logic. Optional `processing` v1 is validated and persisted atomically; optional UUID `reportId` and `encounterId` are described below. `400 {"ok":false,"error":"Expected { watchId, reports: [] }"}`
rejects an invalid batch envelope. `413 {"ok":false,"error":"Max 500 reports per batch"}`
rejects too many reports. Express also rejects malformed JSON (`400`) and bodies
above 1 MB (`413`); all errors use `{ok:false,error:string}`. Database failures return 503 without internal details or acknowledgments.

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
`invalid or over-limit rawText; retain original locally`, invalid processing/evidence/provenance, ambiguous local IDs, and identity conflicts.

The identity is `(trimmed watchId, normalized createdAt)`.
Replay inserts zero rows but returns the duplicate row's supplied `localId` in
`ackLocalIds`. Immutable report fields, validated processing, optional source UUID and explicit encounter links are compared on a collision. Identical replays are acknowledged; different content returns `identity conflict: original report differs` without ACK and does not overwrite the original. A database
failure rolls back the transaction; it must not be treated as receipt.
The watch retains rows on a non-200, timeout or decoding/connection failure;
on 200 it validates the response shape and scopes ACK IDs to the transmitted batch before marking them synced. Contradictory ACK/rejection IDs and malformed responses retain the batch. It still does not independently authenticate the hub. The watch batches at 100 rows and caps encoded bodies at 900 KiB. Originals above 16,000 characters remain queued while other reports can proceed. Byte-aware batching also splits long/multibyte originals below the body limit. Automatic foreground retries run after save, at startup/resume and every 30 seconds on success, with failure backoff of 60/120/240/480 seconds. A manual Retry Now is optional. Rejected rows remain pending and the UI reports an incomplete-sync error. These limitations are recorded in `architecture.md`.

## Stored dashboard rows

`GET /api/triage` returns SQLite column names:
`id`, `watch_id`, `location`, `injuries`, `triage`, `patient_count`, `age_group`,
`eta_minutes`, `raw_text`, `created_at`, `received_at`, `status`.
`id` is the hub's integer ID, distinct from the watch `localId`.
`created_at` is the watch clock; `received_at` is the hub clock.
ETA is minutes after creation, so delayed sync or clock skew affects the countdown.

`sync_status = 1` on the watch means acknowledgment by this LAN endpoint;
`status = arrived` is a separate operator action at the hub. Neither is a
cryptographically verified delivery receipt. Supabase is an independent watch
sync path, not part of this HTTP API: it uses `report_id` UUID upserts, a separate
`cloud_sync_status`, and owner-scoped RLS. The hub separately backs up its
received source reports as its own Supabase user (`hub/cloud.js`, see
`architecture.md`); only the status endpoints above expose it. See
`supabase/migrations/README.md` for the cloud table setup. BLE schemas/endpoints
are not implemented.

## Hospital provisional priority (additive fields)

The original `triage` column remains the source category. `GET /api/triage` adds
`provisional_triage`, `effective_triage`, `risk_reason`, `rule_version` and
`requires_verification: true`, `revision`, `encounter_id`, `source_report_id`,
`receipt_state: received`, `patient_count_known`, `current_transcript`, `processing`,
`uncertainties`, `computed_triage` and `clinician_override`. Assessments are stored
at intake and every clinical revision. Legacy intake uses `legacy-findings-v1`;
structured assessment uses the existing `provisional-v1` rules.

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
text. Clinical correction/override audit APIs are implemented (see "Clinical history
endpoints" below) and status PATCH remains available. The hub-local Qwen preview
routes provide extraction with evidence and deterministic provisional triage;
`POST /api/triage/:id/ai-extract` appends machine extraction to existing SQLite
history. Structured `processing` supplied in a sync batch or revision is validated
by `validateProcessing` and persisted. See docs/ai-contract.md. The Evidence and
corrections dialog displays persisted history and allows
transcript corrections and provisional overrides. It preserves an idempotency ID
while retrying an unchanged edit. Status PATCH remains compatible.


## Structured intake and findings

`processing` v1 uses the envelope in `qwen-agent-handoff.md`: exact
`originalTranscript` (up to 16,000 characters), all four `observations`, up to 30
`uncertainties` (300 characters each), and STT/extraction `provenance`. Local
extraction metadata includes model/revision/runtime/artifact SHA-256 and execution
`local`. The Qwen prototype now verifies repository-managed weights and local runtime execution; physical clinical/hardware validation remains incomplete.

Two optional fields extend that envelope without requiring native clients to change:

- `evidence`: map from observation key to `{source, excerpt, contradictory}`.
  Source is `reported`, `observed` or `model-inferred`; excerpt is nonblank, at
  most 1,000 characters and an exact substring of the current transcript;
  contradictory is a required boolean. Unsupported references reject intake.
- `findings`: up to 100 entries with unique bounded string `id`, `kind`
  (`symptom|observation|vital|patient|incident`), bounded `name`, `value` (bounded
  string, finite number or null), optional `unit`, `source`, `excerpt`, and boolean
  `contradictory`. Source also permits `unavailable`, which requires null value
  and excerpt. Other findings need exact source excerpts. All findings and revisions
  are preserved; arbitrary values never become scoring thresholds.

For triage, a non-unknown observation requires a source excerpt and a reported or
observed source without a contradiction. Conflicting findings with the same
observation name invalidate that observation. Model-inferred values and **all
machine extractions** remain unverified claims and become unknown for assessment;
matching text alone does not prove semantic grounding. A qualified operator can
submit a separate assessment with non-model provenance after verification. This
changes provisional classification only; it does not gate automatic submission.
Missing evidence in older processing envelopes is accepted, preserved, and assessed
as unknown. Unknown breathing never becomes normal; automatic death declaration
is unavailable. `assessRisk` uses only the existing prototype rules documented in
`backend-completion.md`, not a new clinical protocol.

Optional `encounterId` is an offline-generated UUID. An unknown encounter is
created atomically on its first report; subsequent reports link only by that
explicit ID. Without it the hub creates a distinct encounter with unknown patient
identity. Names never merge patients or encounters. Optional `reportId` is a UUID
stored as additional source identity. Reusing it for another legacy identity is
rejected. It does not replace `(watch_id, created_at)`; a replay must preserve the
source UUID presence/value. The current watch sender continues using legacy LAN
identity; its separate cloud UUID remains unchanged.

## Clinical history endpoints

| Method/path | Result |
| --- | --- |
| `GET /api/triage/:id` | Current dashboard row plus immutable `original_submission`, ordered `history`, `events` and current encounter with encounter history. |
| `POST /api/triage/:id/revisions` | Append and reassess, then return the detailed report. |
| `POST /api/patients` | Create an explicitly unknown or reported patient using caller UUID `patientId`. Returns latest revision and complete history. |
| `GET /api/patients/:id` | Current identity and complete history. |
| `POST /api/patients/:id/revisions` | Append a complete identity snapshot; retains earlier records. |
| `POST /api/encounters` | Create caller UUID `encounterId`, optional existing `patientId` (or null), and `incident` (bounded text or null). |
| `GET /api/encounters/:id` | Current encounter and complete history. |
| `POST /api/encounters/:id/revisions` | Append patient linkage and incident snapshot; never merge encounters. |

All creation/revision writes require UUID `requestId`, nonblank `actor` (max 100)
and `reason` (max 500). Revisions additionally require `baseRevision`, a nonnegative
safe integer equal to the current revision; intake/creation starts at revision 0.
Replaying the same request ID and body is idempotent even after later revisions;
a changed body or stale base returns 409. Invalid bodies/IDs return 400, missing
records 404, and database failures 503. Caller UUIDs are normalized to lowercase before identity lookup; actor
and device labels remain self-declared, with no claim of verified identity.

Patient snapshots require `identityStatus: unknown|reported` and `name: string|null`
(max 200; unknown requires null). Verified identity is unsupported without trusted
authentication. Encounter snapshots require `patientId: UUID|null` and
`incident: string|null` (max 1,000). Creation includes its resource ID; subsequent
revisions omit it. Each snapshot is immutable, including its original body.

Report revisions require `kind`:

- `correction`: `transcript` (exact string, max 16,000) and optional validated
  `processing` for that transcript. Clears previous extraction, findings and
  override before reassessment. Source transcript/category/injuries remain intact.
- `extraction`: `processing` for the **current** transcript. A mismatched transcript
  returns 409. Provenance and findings remain traceable to this revision.
- `override`: `override: Immediate|Unassessed|Delayed|Minor|null`. Null clears it;
  computed risk/reason remain visible and immutable in assessment history.
  Deceased override requires a separately defined trusted clinical workflow.

The dashboard is a development interface: overrides are provisional, actor labels
are unauthenticated and `requires_verification` stays true. There is no mandatory
pre-send approval. A durable hub receipt means its transaction committed; only the
client can record that it received the HTTP acknowledgment. It does not establish
trusted hospital delivery, clinical review or arrival. SQL failures roll back the
whole batch; per-report validation failures leave only those rows pending.


## Local Qwen execution and persisted extraction

`GET /api/ai/health` verifies the repository GGUF checksum, configured local runtime,
Ollama imported blob SHA and Qwen architecture, then generates fresh nonempty tokens.
Success is HTTP 200 `{status: "ready", model: "qwen3:0.6b", runtime: "ollama",
model_loaded: true, inference_available: true}`; unavailable/invalid execution is
503 with false flags and an error code. `GET /api/ai/status` remains the cheap
exact-tag check and does not establish generation or clinical readiness.

`POST /api/triage/:id/ai-extract` requires only UUID `requestId` and nonnegative
integer `baseRevision`. It extracts from the **current persisted transcript**,
then appends an extraction revision with actor `Qwen/ollama`. A replay with the
same request/revision returns `{ok: true, report, replay: true}` without new inference
or history. Changed request identity/base, stale revisions and concurrent corrections
return 409. Missing records return 404; invalid input 400; runtime errors 502/503/504;
storage errors 503. No error deletes original data or emits a receipt.

Success returns `{ok: true, processing, evidence, warnings, provisional, model,
promptVersion, report}`. Processing carries exact originals, source excerpts labeled
`model-inferred` and verified model/revision/runtime/artifact SHA with execution
`local`. Advisory provisional output does not replace persisted rule assessment:
machine claims remain excluded until qualified non-model reassessment. Original
source triage/encounter linkage/correction history remain intact; no approval gate
is required for saving or relaying the generated extraction.


## Connectivity additions — 2026-10-10

All API requests return `X-Request-ID`; a valid incoming UUID is preserved, otherwise
a new UUID is assigned. AI responses add `contractVersion: 1` and `requestId` without
changing processing v1 or legacy sync fields. `/api/config` adds the authenticated
principal's ID/role (never credentials) and contract version. Bearer authentication
also applies to SSE; the browser central client uses fetch streaming with three
reconnection attempts, then authenticated polling. The health liveness route remains
public and contains no records. Read the AI contract and `global-ai-connectivity.md`
for readiness states, independent native inference and pairing instructions.
