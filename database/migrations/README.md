# Local schema migration ownership

The watch upgrades its version-1 SQLite database to version 2 in place. The hub
applies its baseline SQLite migration and adopts compatible pre-migration
databases without recreating tables or dropping records, then upgrades through v2. The Supabase migration
must be explicitly applied to the chosen remote project using the Supabase CLI;
adding the file does not change a remote database.

| Owner/path | Existing source of truth | Upgrade integration required |
| --- | --- | --- |
| `watch/` | `../../watch/lib/db/triage_db.dart`: sqflite version 2, `onCreate`, `onUpgrade`, `triage_logs` and `meta` | Version 2 adds stable report UUIDs and independent, owner-scoped cloud-sync state while preserving the hospital queue. |
| `hub/` | `../../hub/db.js` and `../../hub/migrations/0001_initial_schema.sql` | `openDb` applies numbered SQL migrations transactionally with `PRAGMA user_version`; compatible existing report tables are adopted, and incompatible schemas fail without advancing the version. `0002_clinical_history.sql` adds foreign-key-linked patient/encounter/report histories; its JavaScript backfill runs inside the same transaction. |
| Cloud: `../../supabase/migrations/` | `../../supabase/migrations/20261009000000_create_triage_reports.sql` | Apply the versioned PostgreSQL migration to the intended Supabase project; local SQLite SQL is not PostgreSQL SQL. |

Paths in the first column identify each owner; source links are relative to this
directory. Future hub migration files use `NNNN_description.sql` and are applied
by the hub runner. Watch migrations use ordered Dart/sqflite upgrade steps.
Cloud files use Supabase timestamp naming and live only in its migration
directory.

For future schema changes:

1. Capture the current schema as the owner's baseline and inspect existing data.
   Back up persistent data through an approved procedure; never reset the queue.
2. Preserve existing data and implement the owner's transaction/version
   integration. Do not add unapplied SQL and call the feature complete.
3. Test upgrading a populated version-1 database: preserve report content,
   `watch_id`, pending/synced state, hub status, deduplication constraints and index.
   Test reopening and failure rollback, not only creating an empty database.
4. Update sender/receiver/model/dashboard contracts and migration documentation.
   Identify recovery steps; irreversible data changes need explicit authorization.

Never rewrite an applied migration or drop data as a workaround. The initial hub
migration is a baseline of its existing schema; future changes require a new
numbered migration.


Hub v2 enables foreign keys, a five-second lock timeout, WAL and FULL synchronous
commits. `BEGIN IMMEDIATE` serializes migration/intake/revision writers; applied
versions are read inside the migration lock. Startup checks relationships and
rejects missing source history. Existing report IDs, timestamps, source fields,
status and deduplication/indexes remain in the original table. Each legacy row
gets one distinct unknown encounter, immutable intake revision and receipt event;
patient counts are marked uncertain because legacy defaults cannot establish whether
the rescuer supplied them. Reopening never regenerates encounters or assessments.

History tables reject UPDATE/DELETE through triggers. Source report fields reject
UPDATE while the existing status PATCH remains supported and records a status event.
Changes to transcript/findings/identity/linkage use new revisions, not source edits.
Findings, observations and provenance are bounded versioned JSON inside immutable
report snapshots, avoiding unused or duplicated child tables.

Before using a new binary with persistent storage, make an approved SQLite-aware
backup that includes committed WAL data (SQLite backup API or stopped service).
This task tested only temporary and isolated synthetic databases and did not open
`hub/data`. A migration failure rolls back and leaves `user_version` unchanged;
resolve the schema mismatch and retry, without resetting storage. Do not run an old
binary against v2: older code cannot preserve its history; recover using the compatible
binary or an approved pre-upgrade backup, never a schema reset. See
`../../docs/backend-completion.md` for performed upgrade/reopen/concurrency checks.

Legacy baseline assessments are explicitly attributed to `migration` at their
actual computation time; historical source/receipt timestamps remain unchanged.
The backfill does not imply a clinical assessment occurred when the old report
was received.
