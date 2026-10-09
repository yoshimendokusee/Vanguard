# Contribution conventions

- Read `architecture.md` and `api-contract.md`; inspect callers before changing
  shared behavior. Preserve `watch/` and `hub/` and unrelated work.
- Work in `feature/<short-name>`, `fix/<short-name>` or `hotfix/<short-name>` branches.
  Existing `feat/`, `docs/` and `codex/` branches use the same PR gate.
  Use the PR template, review and required CI checks. Do not push directly to
  `main`. See `GITHUB_WORKFLOW.md` and `../.github/branch-policy.md` for CI,
  review requirements and the administrator's GitHub ruleset procedure.
- Keep changes scoped. Reuse helpers and installed dependencies; do not add a
  framework, service or empty future module merely to match the target diagram.
- New feature code belongs with that feature inside its existing app. The current
  small hub remains `server.js` (HTTP), `sync.js` (ingest), `db.js` (storage) and
  `public/` (presentation). Extract modules only as real feature boundaries arise.
- JavaScript: CommonJS, two spaces, semicolons, single quotes and Node's built-in
  test runner, following the hub. No invented lint/build commands for plain JS.
- Dart: `dart format` for edited Dart files, lower_snake_case filenames, existing
  Flutter lints, `flutter_test`. Avoid reformatting unrelated files.
- JSON/HTTP fields use current camelCase; SQLite/dashboard rows use snake_case.
  Triage/age/status values are case-sensitive; coordinate changes across parser,
  watch storage/model, sender, hub validation/schema, dashboard, fixtures and tests.
- Use UTC ISO timestamps at interfaces. Do not use timestamp identity or device
  clocks as security credentials. Preserve legacy IDs during a future migration.
- Validate at trust boundaries, use prepared SQL and `textContent` for transcripts.
  Preserve error handling, pending reports, uncertainty and accessibility.
- Never log/store/commit real patient fixtures or secrets. Examples and tests use
  synthetic data. Native signing keys and server credentials stay out of Git and
  client builds. `.env` is local; Node does not auto-load it (see README).
- Schema changes follow `../database/migrations/README.md`, including populated
  database upgrade tests; resets are not migrations. Never edit an applied migration.
- Relevant checks: hub `npm ci && npm test`; watch `flutter pub get`,
  `flutter analyze`, `flutter test`; Docker `docker compose config --quiet`,
  build and in-image tests with in-memory storage. Add meaningful tests for new
  logic, and document unrun checks and hardware blockers.
- Update the API contract and architecture when behavior or implementation status
  changes. Put observed limitations in the dated reverse-engineering report;
  never promote a target or historical test claim to verified behavior.
