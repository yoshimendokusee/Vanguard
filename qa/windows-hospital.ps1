param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$report = Join-Path $PSScriptRoot 'windows-results.txt'
Set-Location $repo

function Run-Docker {
  & docker @args | Tee-Object -FilePath $report -Append
  if ($LASTEXITCODE -ne 0) {
    "FAIL: Docker command $args" | Add-Content $report
    throw "Docker command failed: $args"
  }
}

function Wait-Hub {
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try {
      $health = Invoke-RestMethod http://127.0.0.1:3301/api/health
      if ($health.ok) { return }
    } catch { Start-Sleep -Seconds 1 }
  }
  throw 'QA hospital did not become ready'
}

"Windows QA $(Get-Date -Format o)" | Set-Content $report
Run-Docker version
Run-Docker compose config --quiet
Run-Docker compose -f hub/docker-compose.yml config --quiet
Run-Docker compose -f hub/compose.qa.yaml -p vanguard-qa config --quiet
if (-not $SkipBuild) { Run-Docker build --tag vanguard-hospital-qa hub }
# No mounted database and no network; fixtures are synthetic.
Run-Docker run --rm --network none --env DB_PATH=:memory: `
  --mount "type=bind,source=$repo/docs,target=/docs,readonly" `
  --mount "type=bind,source=$repo/watch/lib,target=/watch/lib,readonly" `
  vanguard-hospital-qa npm test
Run-Docker compose -f hub/compose.qa.yaml -p vanguard-qa up -d --build
try {
  Wait-Hub
  Run-Docker compose -f hub/compose.qa.yaml -p vanguard-qa exec -T hub node qa/check.cjs
  Run-Docker compose -f hub/compose.qa.yaml -p vanguard-qa restart hub
  Wait-Hub
  Run-Docker compose -f hub/compose.qa.yaml -p vanguard-qa exec -T hub node qa/check.cjs --expect-existing
  'PASS: backend regressions, provisional priority, duplicate/conflict protection and restart persistence' | Tee-Object -FilePath $report -Append
  'MANUAL: browser, disconnected-WAN operation and Qwen execution remain to be recorded.' | Tee-Object -FilePath $report -Append
} catch {
  "FAIL: $($_.Exception.Message)" | Tee-Object -FilePath $report -Append
  throw
}
# Leave the isolated QA hospital running for manual browser checks. No volume deletion.
