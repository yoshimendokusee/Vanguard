# Windows hospital QA

Use synthetic data only. Docker Desktop in Linux-container mode and Compose
2.20.3+ are sufficient; no macOS, Flutter or native Node installation is needed.
Build images while online. The current hospital remains HTTP without auth/TLS;
QA binds localhost and never mounts the normal `hub/data` directory.

From PowerShell at the repository root:

```powershell
./qa/windows-hospital.ps1
```

Use your organization's normal PowerShell script policy; the workflow does not
change execution policy. Results go to `qa/windows-results.txt`. Any failed
command stops the script. `-SkipBuild` reuses the standalone test image; Compose
still ensures the QA service image is current. Builds and dependency provisioning
need connectivity; running the provisioned hospital does not.

The script validates root and legacy Compose, runs backend regressions with
`--network none` and an in-memory DB, starts an isolated QA hospital, submits four
fixed synthetic reports, checks provisional priority, duplicate acknowledgments
and conflict rejection, restarts the service, then asserts the original four rows
still exist. A named QA volume holds SQLite across restarts. It does not delete
volumes, clear queues, or touch production/demo data.

For the normal hospital, either entry point remains supported (choose one):

```powershell
docker compose up -d --build
# Or:
docker compose -f hub/docker-compose.yml --env-file .env up -d --build
```

These use the original `hub/data`. Do not submit QA fixtures there if it contains
existing reports. For QA use the isolated service at
[localhost:3301](http://localhost:3301).

## Manual result record

Append actual PASS/FAIL/BLOCKED results to `qa/windows-results.txt` with Windows,
Docker, browser and GPU versions and the tested Git revision. Automated Linux
container results from a Mac do not establish Windows-host behavior.

| Check | Procedure | Pass evidence |
| --- | --- | --- |
| Browser | Open localhost:3301 | Severe bleeding first, unknown second, fracture third, abrasion fourth; source category remains visible |
| Local rules | Inspect each card | Rule version, triggering finding and clinician-verification label visible |
| Duplicate prevention | Run `docker compose -f hub/compose.qa.yaml -p vanguard-qa exec -T hub node qa/check.cjs` again | Four rows, replay acknowledged, conflicting original rejected |
| SQLite persistence | Restart QA hub and run checker with `--expect-existing` | Four original rows existed before resubmission |
| Offline hospital | Disconnect WAN after provisioning; keep Docker running; reload localhost:3301 and run checker | API and dashboard still work, no external assets requested |
| Outage | Stop hub, then start it using the same QA Compose project | Original rows return; do not use `down -v` |
| Corrections/overrides | Await database teammate's durable audit integration | BLOCKED now; never fake success using browser-only state |
| Browser Qwen | Follow `qwen-agent-handoff.md` after runtime integration | BLOCKED now; require actual new-token generation with network disabled, pinned artifacts/runtime and evidence |

Browser-local inference and an offline backend are separate tests. A downloaded
model, successful page load or Docker build is not local inference evidence.

Stop the QA hospital without deleting its data:

```powershell
docker compose -f hub/compose.qa.yaml -p vanguard-qa down
```
