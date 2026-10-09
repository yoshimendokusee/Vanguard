#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prepared images are mandatory. No builds/pulls occur during acceptance.
project="vanguard-qwen-offline-${QWEN_TEST_RUN:-$(date +%s)}"
compose=(docker compose -p "$project" -f qa/qwen-offline.compose.yaml)
echo "Synthetic offline acceptance project: $project"
node -e 'require("./hub/model").verifyModel().catch(e => {console.error(e.message); process.exitCode=1;})'
docker image inspect vanguard-qwen-qa:local >/dev/null
docker image inspect ollama/ollama:0.11.4 >/dev/null
"${compose[@]}" up -d --no-build --pull never
trap '"${compose[@]}" stop >/dev/null; echo "Synthetic volumes retained for $project"' EXIT
# The checker imports ../hub from scripts; maintain its repository path in-container.
"${compose[@]}" exec -T hub mkdir -p /scripts
"${compose[@]}" cp scripts/qwen-check.cjs hub:/scripts/qwen-check.cjs
"${compose[@]}" exec -T hub ln -s /app /hub
"${compose[@]}" exec -T hub node - <<'JS'
const assert = require('node:assert/strict');
(async () => {
  // Verify real external egress is blocked, independently of inference success.
  await assert.rejects(fetch('https://1.1.1.1', { signal: AbortSignal.timeout(3000) }));
  for (let attempt = 0; attempt < 90; attempt++) {
    try {
      const response = await fetch('http://127.0.0.1:3000/api/ai/health', { signal: AbortSignal.timeout(120000) });
      if (response.ok && (await response.json()).inference_available) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw Error('Local Qwen never became ready');
})().catch(error => {console.error(error.message);process.exitCode=1;});
JS
"${compose[@]}" exec -T hub node /scripts/qwen-check.cjs hub http://127.0.0.1:3000
"${compose[@]}" exec -T hub node - <<'JS'
const fs = require('node:fs');
fetch('http://127.0.0.1:3000/api/triage').then(r => r.json()).then(rows => {
  fs.writeFileSync('/data/qwen-before-restart.json', JSON.stringify(rows));
});
JS
"${compose[@]}" restart ollama hub
"${compose[@]}" exec -T hub node - <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
(async () => {
  const before = JSON.parse(fs.readFileSync('/data/qwen-before-restart.json'));
  for (let attempt = 0; attempt < 90; attempt++) {
    try {
      const health = await fetch('http://127.0.0.1:3000/api/ai/health');
      if (health.ok) {
        const after = await (await fetch('http://127.0.0.1:3000/api/triage')).json();
        assert.deepEqual(after, before, 'Persisted reports changed on restart');
        console.log('PASS: offline runtime/backend restart, transcripts/provenance retained'); return;
      }
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw Error('Restart recovery failed');
})().catch(error => {console.error(error.message);process.exitCode=1;});
JS
echo 'BLOCKED: physical iPhone/Watch restarts, disconnection/reconnection and offline speech require hardware.'
echo 'Docker offline acceptance PASS; full cross-platform offline acceptance remains BLOCKED.'
exit 2
