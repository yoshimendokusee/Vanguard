#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0; blocked=0
check() {
  label="$1"; shift
  if "$@"; then echo "$label PASS"; else echo "$label FAIL"; failed=1; fi
}
check 'Repository weights/checksum' node -e 'require("./hub/model").verifyModel().then(m=>console.log(m.model,m.sha256)).catch(e=>{console.error(e.message);process.exitCode=1;})'
check 'Ollama initialization/identity/real tokens' ./scripts/qwen-echo.sh
if [[ -n "${QWEN_TEST_HUB_URL:-}" ]]; then
  check 'Backend persistence and web route' node scripts/qwen-check.cjs hub "$QWEN_TEST_HUB_URL"
else echo 'Backend/web live integration BLOCKED: set QWEN_TEST_HUB_URL to an isolated synthetic test hub'; blocked=1; fi
if [[ -n "${QWEN_IOS_SIM:-}" ]]; then
  check 'iOS simulator native inference' ./scripts/qwen-apple-smoke.sh ios "$QWEN_IOS_SIM"
else echo 'iOS native inference BLOCKED: set QWEN_IOS_SIM'; blocked=1; fi
if [[ -n "${QWEN_WATCH_SIM:-}" ]]; then
  check 'watchOS simulator native inference' ./scripts/qwen-apple-smoke.sh watchos "$QWEN_WATCH_SIM"
else echo 'watchOS native inference BLOCKED: set QWEN_WATCH_SIM'; blocked=1; fi
check 'Native storage/fallback recovery regression' xcrun swift test --package-path watch/apple
echo 'Physical iPhone/Watch inference, Watch Connectivity interruption/reconnect, thermal/battery behavior BLOCKED: physical device evidence required'
blocked=1
if [[ "$failed" = 1 ]]; then exit 1; fi
if [[ "$blocked" = 1 ]]; then exit 2; fi
