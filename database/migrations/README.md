# Local schema migration ownership

This layout reserves migration history; there are no executable migrations or
migration runner yet. Adding this folder does not upgrade or reset a database.

| Owner/path | Existing source of truth | Upgrade integration required |
| --- | --- | --- |
| `watch/` | `../../watch/lib/db/triage_db.dart`: sqflite version 1, `onCreate`, `triage_logs` and `meta` | Increment the schema version and implement transactional `onUpgrade` steps before changing existing columns. |
| `hub/` | `../../hub/db.js`: `CREATE TABLE IF NOT EXISTS triage_reports`, index, CHECK and UNIQUE constraints | Add a version/history mechanism and transactional application before changing the existing schema. |
| Cloud: `../../supabase/migrations/` | No Supabase schema exists | Use Supabase migration tooling when cloud implementation is added; local SQLite SQL is not PostgreSQL SQL. |

Paths in the first column are directories within `database/migrations/`; source
links are relative to this directory. Future local migration files use
`NNNN_description.sql` where SQL fits the owner. Watch migrations may instead
need ordered Dart steps integrated with sqflite; document each step here. Cloud
files use Supabase's timestamp naming and live only in its migration directory.

Before the first schema change:

1. Capture the current schema as the owner's baseline and inspect existing data.
   Back up persistent data through an approved procedure; never reset the queue.
2. Implement the owner's upgrade runner and transaction/version integration.
   Do not add unapplied SQL and call the feature complete.
3. Test upgrading a populated version-1 database: preserve report content,
   `watch_id`, pending/synced state, hub status, deduplication constraints and index.
   Test reopening and failure rollback, not only creating an empty database.
4. Update sender/receiver/model/dashboard contracts and migration documentation.
   Identify recovery steps; irreversible data changes need explicit authorization.

Never rewrite an applied migration or drop data as a workaround. The current
foundation intentionally leaves `hub/db.js` and the watch version-1 schema intact.
