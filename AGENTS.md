# Vanguard-Wrist agent guardrails

Read `docs/architecture.md` before changing code. It is the source of truth for
the approved target and the implemented prototype; a target component is not an
existing feature. Read `docs/api-contract.md` for integrations and
`docs/conventions.md` for contribution rules.

## Inspect and preserve

- Check Git status and read the affected code, callers, tests, configuration and
  fixtures before editing. Preserve existing functionality and unrelated changes.
- Keep `watch/` and `hub/` in place. Do not relocate applications, replace working
  frameworks, introduce microservices or expand scope without user authorization.
- Preserve the offline-first modular monolith, three-tier separation and monorepo.
  Organize new functionality by feature within the existing applications; reuse
  existing helpers. Do not scaffold empty apps or add unnecessary dependencies.
- Do not commit, push, merge, deploy or change remote repository settings unless
  the user asks. Use feature branches and reviewed PRs for team integration.

## Reports, triage and storage

- Save reports to local SQLite before attempting any transport. Report capture
  must not depend on internet, a hospital, Docker, BLE or a cloud AI service.
- Preserve pending data on errors and interrupted transfers. Never delete/reset
  persistent databases, rewrite applied migrations or discard queues without
  explicit authorization. Never use a schema reset as an upgrade strategy.
- Follow `database/migrations/README.md`. Coordinate schema changes with readers,
  writers, sync contracts and upgrade tests using existing populated databases.
- Keep the current `(watch_id, created_at)` LAN identity compatible until a tested
  migration to globally unique report IDs is authorized and implemented.
- Mark only explicitly acknowledged reports as synced. Relay receipt and cloud
  upload are not hospital delivery. Future delivery confirmation requires a trusted
  hospital acknowledgment, safe retries and durable deduplication.
- Keep triage deterministic and provisional. A future local LLM may extract fields;
  it must not invent findings or independently assign clinical urgency. Preserve
  unknown/unassessed reports and require qualified human verification.

## Contracts, security and platforms

- Validate external input; preserve prepared SQL and safe text rendering. Update
  shared contracts, callers and relevant tests together. Do not silently break APIs.
- Never commit or print credentials, signing keys, database contents or patient
  transcripts. Use synthetic fixtures and least privilege. `.env.example` contains
  configuration examples only; never put server secrets in client builds.
- Current HTTP LAN access and SQLite storage are unauthenticated/unencrypted.
  Do not describe them as secure, deploy them for real patient use or expose them
  to shared/public networks. Target work requires authenticated devices/users,
  protected storage/transports and Supabase RLS before handling real patient data.
- Docker runs the hospital service and its dashboard, not native watch/mobile apps
  or hardware BLE. Preserve both root and `hub/` Compose entry points and data paths.
- BLE store-and-forward is planned. Do not promise continuous connectivity,
  cross-platform background reliability or delivery without target-device evidence.
  Document supported OS/device states, failed transfers and platform restrictions.

## Verification and reporting

- Hub: `cd hub && npm ci && npm test`; watch: `cd watch && flutter pub get &&
  flutter analyze && flutter test`. Run the checks relevant to the change.
- On Windows with Node 24, `npm ci` fails (no `better-sqlite3` 13 prebuild, no
  C++ tools). Run hub tests in the Node 22 image instead:
  `docker build -t vanguard-hub-test ./hub` then `docker run --rm -e DB_PATH=:memory:
  -e LIVE_AI=0 -v <repo>/docs:/docs:ro -v <repo>/watch/lib:/watch/lib:ro
  vanguard-hub-test node --test` (contract tests read `docs/` and `watch/lib/`).
- Hub Supabase backup reads `SUPABASE_*` from the git-ignored root `.env`; plain
  `docker run --env-file` keeps quotes literally, so use Compose or `node --env-file`.
- Docker changes: validate both Compose files, build, and run hub tests in the
  image using an in-memory database. Do not run demos against an existing data store.
- New non-trivial logic requires a meaningful regression test or self-check.
- Never claim unrun tests, hardware behavior or hosted CI passed. Report commands,
  results, blockers, changed files and remaining risks; distinguish historical
  claims from checks performed now. Update documentation when behavior changes.

These instructions guide agents; CI checks enforce only the checks they run.
Branch protection is configured separately by repository administrators.
