# GitHub workflow for the four-person team

Keep `watch/` and `hub/` in place. Docker runs the hospital API and its static
dashboard; it does not run native watch/mobile applications. Work by feature
inside the existing applications and coordinate shared contracts and storage.
The supported target platforms are Apple Watch, iPhone and the hospital web app.
The current `watch/` is a legacy Flutter/Wear OS prototype; preserve it while the
approved Apple implementation is introduced. This CI work adds no native apps.

## Start feature work

Begin with a clean working tree. Commit your own work on its feature branch or
otherwise preserve it before switching; never discard another developer's edits.

```bash
git status
git switch main
git pull --ff-only origin main
git switch -c feature/report-generation
```

Use `feature/authentication`, `feature/dashboard`, `feature/patient-management`
or `feature/report-generation` for those features. Use `fix/<description>` and
`hotfix/<description>` as appropriate. These examples are not requests to create
empty branches or applications. Existing `codex/` and `feat/` branches still use PRs.

Before changing shared behavior, read `architecture.md`, `api-contract.md` and
the migration README. Tell the affected teammate when changing the sender,
receiver, database, category values, environment variables or CI configuration.
The four members can own Watch processing, client data/sync, hub/contracts and
dashboard/testing respectively; review should cross the affected boundary.

## Validate, commit and open a PR

```bash
node --test .github/scripts/validate-repository.test.js
node .github/scripts/validate-repository.js
git diff --check
cd hub
npm ci
npm test
cd ../watch
flutter pub get --enforce-lockfile
dart format lib test
flutter analyze --no-pub
flutter test --no-pub
cd ..
docker compose config --quiet
docker compose -f hub/docker-compose.yml config --quiet
```

No Android build or SDK setup is required. Existing Flutter checks preserve the
legacy parser/source baseline. No watchOS/iOS targets exist, so no Apple build or
device acceptance is claimed. Add Xcode build/tests when those targets arrive;
never add signing credentials or model weights to Git.

For a container check, build once and run without the persistent database mount:

```bash
docker build -t vanguard-ci:local hub
docker run --rm --network none --env DB_PATH=:memory: \
  --mount "type=bind,source=$PWD/docs,target=/docs,readonly" \
  --mount "type=bind,source=$PWD/watch/lib,target=/watch/lib,readonly" \
  vanguard-ci:local npm test
```

The read-only mounts provide the shared contract and native sender/parser source
for integration tests. Tests use synthetic in-memory or disposable temporary
databases. Never mount `hub/data` for CI or reset a persistent database.

Inspect the diff, stage specific intended files, then commit and push the feature:

```bash
git diff
git add path/to/changed-file
git commit -m "Describe the resulting behavior"
git push -u origin feature/report-generation
gh pr create --base main --fill
```

Fill in the PR template: summary, affected feature, related task, affected teammate
modules, API/database changes, actual tests, UI screenshots and known limitations.
Never stage `.env`, credentials, signing files, databases or patient data.

## Automatic CI and failures

`pr-ci.yml` runs on PR open, new commits, reopen and ready-for-review against
`main`, and pushes to `main`; manual dispatch is also available after integration.
Older runs for the same PR are cancelled. All jobs use read-only repository access;
there is no `pull_request_target`, privileged PR execution, deployment or merge job.
Action revisions and downloaded scanner/linter checksums are pinned.

The workflow preserves the existing three check names and adds repository
validation, secret scanning and an acceptance gate. See
[`branch-policy.md`](../.github/branch-policy.md) for the exact six names.
The gate writes a PASS/FAIL table to the run summary and fails for skipped or
cancelled jobs too. Dependency caches cover npm and Flutter; the image builds once.

Open **PR → Checks → failing job → failing step** or run:

```bash
gh pr checks
gh run view RUN_ID --log-failed
```

Reproduce the step locally, fix the cause and push another commit. Failed tests,
formatter changes, incompatible locks and missing configuration must be fixed;
do not add `continue-on-error`, skip required jobs or bypass protection.
For a secret finding, revoke/rotate the exposed credential and coordinate safe
remediation; removing it in a later commit does not remove it from history.
Gitleaks findings are redacted, and no secret report is uploaded.

There is no JS lint/type-check command, frontend build system or OpenAPI file in
this repository. CI checks JS syntax and whitespace, runs the documented HTTP
example and compiles dashboard inline JS. Flutter analysis provides Dart static
and type checks. This does not establish browser rendering or native hardware
behavior. The Markdown API contract stays the shared integration fixture; a future
OpenAPI schema needs its own validator rather than a placeholder.

No migration runner exists. CI rejects executable migrations in the reserved
folders until the owner integrates a runner and populated upgrade/rollback tests,
then updates that guard. Existing synthetic reopen tests verify the current hub
schema only; they are not proof of a future migration's safety. Environment checks
cover the existing application configuration readers; add new readers to the
validator when introducing them. Required teammate review covers shared changes
that automation cannot assess semantically.

## Review and update

When checks pass, request one of the other three developers:

```bash
gh pr edit --add-reviewer TEAMMATE_LOGIN
```

Replace the example with an actual collaborator; no identities or CODEOWNERS
have been invented. The author cannot supply their own required approval. Shared
changes should be reviewed by the teammate consuming that contract or module.

Address feedback with new commits, explain the change in the PR, rerun checks and
request review again. Resolve each conversation after its concern is addressed.
New reviewable changes dismiss stale approval; approval is needed for the latest
push. Passing CI alone never grants merge permission.

## Update from main and resolve conflicts

For a shared feature branch, prefer merging current `main` into it so no force
push is needed. Linear history is required on `main`, not on feature branches.

```bash
git status
git fetch origin
git switch feature/report-generation
git merge origin/main
```

If conflicts occur, use `git status`, read both sides and coordinate with the
other module owner. Preserve both intended behaviors, edit the conflicting files,
stage those files and complete the merge. Use `git merge --abort` if the resolution
is not understood; do not select one entire side to silence a conflict. Repeat
the relevant local checks, then push and obtain fresh teammate review.

## Merge safely

Confirm all required checks passed on the current, up-to-date PR; another developer
approved it and conversations are resolved. A developer chooses **Squash and merge**
manually, or runs `gh pr merge --squash` after those conditions are met. Never use
`--admin` or `--auto`. GitHub-enforced rules determine eligibility, not a checklist
or successful workflow alone. `main` cannot be force-pushed or deleted when the
policy is active. Hotfixes follow the same review/check gate.

After merging, update local `main` using `git pull --ff-only origin main`. Feature
branch deletion is optional after teammates have finished using it. Hosted CI and
enforcement only start after the implementation is published and GitHub accepts
the policy; local files do not activate them.

## Checks performed on 2026-10-09

| Command/check | Result |
| --- | --- |
| `node --test .github/scripts/validate-repository.test.js` | PASS, 6 tests; includes failing/skipped/cancelled/missing-job gate rejection |
| `node .github/scripts/validate-repository.js` | PASS; configuration, environment examples and six check names agree with policy |
| `npm ci && npm test` in `hub/` | PASS; locked install and 9 tests, including documented API/dashboard integration and populated database reopen |
| `flutter pub get --enforce-lockfile`, `flutter analyze --no-pub`, `flutter test --no-pub` in `watch/` | PASS; clean analysis and 12 legacy parser tests |
| `dart format --output=none --set-exit-if-changed lib test` | PASS; 6 formatted files; each diff independently matched formatter output for original source |
| Actionlint 1.7.12, Node syntax, `bash -n fake-watch.sh`, `git diff --check` | PASS; workflow YAML/expressions and local source syntax/whitespace |
| Gitleaks 8.30.1, redacted Git history and current non-ignored files | PASS; no detected secrets; generated synthetic credential returned nonzero exit code 7 |
| Both `docker compose config --quiet` entry points | PASS |
| `docker build -t vanguard-ci:local hub` and isolated image test command above | PASS; 9 tests on Linux arm64, networking disabled, no persistent data mount |
| GitHub ruleset and effective-main-rules APIs | PASS; active policy and squash-only/no-auto-merge settings read back |

Actionlint and Gitleaks release downloads were checked against pinned SHA-256
checksums. No application dependencies or schema were changed. No native Apple
build, hardware test, browser rendering test, live PR rejection experiment or
hosted run of `pr-ci.yml` was performed. Android build validation was removed at
the user's request. The earlier Android attempt lacked an SDK and is not a check
for the approved platform scope.

The settings are active; committing/pushing the new workflow and integrating its
first reviewed PR are pending. Other PRs without the new check names are blocked.
