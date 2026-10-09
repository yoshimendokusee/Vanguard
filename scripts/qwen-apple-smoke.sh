#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:?Use ios or watchos}"; device="${2:?Supply an available simulator UDID}"
case "$platform" in
  ios) scheme=VanguardPhone; destination='generic/platform=iOS Simulator'; products=Debug-iphonesimulator; bundle=ph.vanguard.ios ;;
  watchos) scheme=VanguardWatch; destination='generic/platform=watchOS Simulator'; products=Debug-watchsimulator; bundle=ph.vanguard.ios.watch ;;
  *) echo 'Expected ios or watchos' >&2; exit 1 ;;
esac
node -e 'require("./hub/model").verifyModel().catch(e=>{console.error(e.message);process.exitCode=1;})'
xcodebuild -project watch/apple/Vanguard.xcodeproj -scheme "$scheme" -destination "$destination" \
  -derivedDataPath watch/apple/DerivedData CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build > "/tmp/vanguard-$platform-build.log" 2>&1
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "watch/apple/DerivedData/Build/Products/$products/$scheme.app"
container="$(xcrun simctl get_app_container "$device" "$bundle" data)"
# A fresh launch writes a distinct artifact; stale PASS cannot satisfy this run.
previous="$(stat -f %m "$container/Documents/qwen-smoke.json" 2>/dev/null || echo 0)"
xcrun simctl launch --terminate-running-process "$device" "$bundle" --qwen-smoke
for attempt in $(seq 1 150); do
  current="$(stat -f %m "$container/Documents/qwen-smoke.json" 2>/dev/null || echo 0)"
  if [[ "$current" -gt "$previous" ]]; then
    python3 - "$container/Documents/qwen-smoke.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1])); print(json.dumps(result,indent=2))
assert result['status']=='PASS', 'Native inference or persistence failed'
assert result['generated']['generatedTokens']>0 and result['originalPreserved'] and result['sqlitePersisted']
assert result['hardwareVerified'] is False
PY
    exit 0
  fi
  sleep 1
done
echo 'FAIL: native app did not produce fresh completion evidence; inspect simulator crash logs' >&2
exit 1
