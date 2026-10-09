# Main branch policy

`main` is the protected integration branch. Feature work uses `feature/<name>`,
bug fixes use `fix/<description>` and urgent fixes use `hotfix/<description>`.
Existing `codex/` and legacy `feat/` branches can finish through the same PR gate.
Branch names are a team convention, not a restriction preventing collaborators
from opening PRs.

## Required enforcement

The supported REST ruleset payload is [rulesets/main.json](rulesets/main.json).
It targets `refs/heads/main` with active enforcement and no bypass actors:

- Pull request required; one approving teammate review. GitHub does not count
  the author's approval. The latest reviewable push also requires another person's
  approval, and new reviewable commits dismiss stale approvals.
- All review conversations resolved.
- All six checks below required from GitHub Actions (integration ID `15368`,
  verified against this repository's existing check runs).
- PR branch up to date with `main`; no merge queue is configured.
- Linear history; squash is the only permitted PR merge method.
- No force pushes or branch deletion. No developer, admin, app or deploy-key
  bypass actors. Requiring PRs blocks direct code pushes; do not add the `update`
  rule with an empty bypass list, because that would block PR merges too.
- No automatic merge. CI never approves or merges a PR.

| Required check | Scope |
| --- | --- |
| Repository validation | Structure, configuration, policy self-tests, whitespace and workflow lint |
| Secret scan | Redacted Gitleaks scan of fetched Git history |
| Hub tests | Locked dependencies, JS syntax, API/dashboard integration and persistence tests |
| Watch analysis and parser tests | Existing Dart dependencies, formatting, analysis and parser regressions; no Android build |
| Compose and container tests | Both Compose files, one image build and isolated in-image tests |
| PR acceptance gate | Fails if any dependency fails, is skipped, cancelled or missing; publishes summary |

Check names must change in the workflow and ruleset together. A local self-check
enforces this correspondence. Do not rename checks already required on GitHub
without coordinating the remote rule update.

## Apply and verify as a repository administrator

This file and the JSON do not enforce anything until GitHub accepts an active
ruleset. Private repositories require an eligible plan; GitHub documents public
rulesets on Free and public/private rulesets on Pro, Team and Enterprise Cloud.
Do not change repository visibility to work around plan restrictions.

Run from the repository root with an authenticated administrator account:

```bash
gh api repos/yoshimendokusee/Vanguard/rulesets
gh api --method POST repos/yoshimendokusee/Vanguard/rulesets \
  --input .github/rulesets/main.json
gh api repos/yoshimendokusee/Vanguard/rules/branches/main
```

If this named ruleset already exists, inspect it and update its ID using `PUT`
instead of creating duplicates. Preserve stronger pre-existing rules and all
unrelated repository settings. Never add a bypass just to merge failing code.

Disable automatic merge and select squash-only repository merge options:

```bash
gh api --method PATCH repos/yoshimendokusee/Vanguard \
  -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F allow_auto_merge=false
gh api repos/yoshimendokusee/Vanguard \
  --jq '{allow_squash_merge,allow_merge_commit,allow_rebase_merge,allow_auto_merge}'
```

The first CI PR must include `pr-ci.yml` and run all six checks. Activating this
policy before that PR is published intentionally blocks other PRs missing the
new checks; land the CI PR first. Subsequent PRs must update from `main`.
Committing, pushing and merging remain developer actions, not CI actions.

Verify the returned ruleset has `enforcement: active`, the exact main condition,
an empty bypass list and all required review/check rules. Verify the effective
branch rules endpoint, not just the local JSON. Administrative access to edit
rules cannot be removed by an empty bypass list; it prevents bypassing merges,
not an administrator deliberately changing repository policy.

If the API returns a permission/plan error, protection is **pending**. The workflow
can run but cannot itself prohibit merging or direct pushes. Upgrade the account
plan if necessary, then repeat application and verification. Do not claim failed
settings changes as successful enforcement.

References: [GitHub ruleset availability](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository),
[supported REST ruleset fields](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset).

## Verification from this implementation

On 2026-10-09, authenticated API access confirmed `main` is the default branch,
the account has repository administrator permission, and no rulesets or legacy
branch protection existed before this change. The private repository accepted
the active ruleset above as ID `24779618`.

Both `GET /repos/yoshimendokusee/Vanguard/rulesets/24779618` and the effective
`rules/branches/main` endpoint confirmed all six required checks, strict updates,
review/conversation requirements, deletion/force-push restrictions and linear
history. The ruleset has no bypass actors. Repository settings were updated and
read back: squash enabled, merge commits/rebase/automatic merge disabled.

The policy is [active on GitHub](https://github.com/yoshimendokusee/Vanguard/rules/24779618).
The new workflow remains local and uncommitted; the remote still has `ci.yml`.
Publishing and integrating this CI change is pending. Until a PR supplies the
new checks, it cannot satisfy this policy. No commit, push, PR, merge, denied-push
experiment or deployment was performed as part of this implementation.

The supported product targets are Apple Watch, iPhone and the hospital web app.
No Android build or SDK setup is in this workflow. The existing Dart checks protect
legacy source/parser behavior; they do not establish Apple platform support.
Native Apple build/verification checks must be added alongside real targets and
their actual deployment versions, signing requirements and hardware acceptance.
