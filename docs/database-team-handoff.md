# Database teammate integration contract

Database implementation was removed from this agent's scope at the user's request
on 2026-10-09. This branch leaves `hub/db.js`, `watch/lib/db/triage_db.dart`,
existing schema/migration files and persistent data unchanged. No migration runner
or SQLite upgrade is provided. Read `database/migrations/README.md` before work.

The current hub refuses additive `processing` reports without ACK, and refuses
legacy `rawText` longer than 1,000 characters. These guards prevent silent metadata
loss. Remove those guards only after storing originals/provenance/uncertainty
transactionally and testing an upgrade of populated existing databases.

## Required durable behavior

- Preserve the existing `(watch_id, created_at)` identity and all legacy report
  fields/statuses. Replays compare immutable originals and ACK identical reports;
  different originals under the same identity stay rejected/pending.
- Add versioned transactional upgrades, a captured baseline and immutable applied
  migration history. Test populated upgrades, reopen, rollback, index/uniqueness
  preservation, pending/synced rows and restart/clock-rollback identity collisions.
  Never reset storage, edit applied migrations or migrate to UUID identity without
  coordinating and testing the existing callers.
- Persist `processing` v1 from `qwen-agent-handoff.md`, including exact originals,
  extraction/STT provenance and uncertainties. Validate via `hub/processing.js`.
  Reject unsupported versions/oversize data; no truncation of originals.
- Keep corrections separate from originals. An append-only audit records actor,
  reason, corrected transcript/observations/override, time, request ID and base
  revision. Store machine extraction provenance too. A transcript correction
  invalidates stale extracted facts until new observations are supplied.
- Idempotent correction/attempt IDs with different content must conflict. A stale
  base revision must conflict rather than overwrite another clinician's changes.
  Clinician priority override and clearing it must preserve computed risk and its
  rule explanation. Actor labels are self-declared until authentication exists.
- Report capture/outbox writes precede all network activity. Only exact hospital
  ACKs scoped to transmitted rows update delivery state. A paired-phone receipt
  means durable relay receipt, never hospital delivery.

## Apple library port

Implement `FallbackRepository` in `watch/apple/Sources/VanguardApple/FallbackProcessor.swift`:

- `pendingCaptures()` returns only complete persisted Watch failure captures with
  original Watch identity/time and an existing retained local audio file.
- `commitProcessed(capture:transcript:processingJSON:)` atomically stores transcript,
  provenance/uncertainty and the hospital outbox, then marks that capture processed.
  A failure leaves the original capture pending. The function must be idempotent.
- Copy received WatchConnectivity files into durable application storage inside
  the receive callback before it returns; persist intake before receipt ACK.
  Bound/validate file size, format, metadata and checksums. Retain audio until the
  agreed durable completion policy; do not delete it on relay completion.
- Wire recovery to intake, app activation and permitted retry/background wakeups.
  Respect OS suspension; do not promise continuous background processing.

The library's repository/processor fixtures are isolated XCTest state fixtures,
not a SQLite implementation or inference evidence. Complete native app targets,
microphone/privacy configuration and paired-device transport in coordination with
the platform owner.

## Hospital interface integration

Keep existing API response fields and status PATCH working. Add audited correction
and extraction endpoints with revision/request IDs and documented validation.
Return the immutable source category plus provisional/effective categories, rule
version/reason, corrections and verification state. Existing `riskForRow` currently
computes legacy priority on read. Integrate validated structured observations with
`assessRisk` and display clinician override separately from the automated result.

Coordinate the API, dashboard, native serialization, tests and Windows checker in
the same integration. Do not implement browser-only correction state or acknowledge
processing the hub cannot preserve. Add synthetic end-to-end correction, override,
replay/conflict and populated upgrade tests to `hub/` using its Node test runner.
