#!/usr/bin/env bash
# Vanguard Watch Qwen3-0.6B native inference diagnostic.
#
# Builds, installs and launches VanguardWatch in an Apple Watch simulator, then
# drives the app's own local QwenEngine through a battery of real prompts and
# inspects the evidence the app writes. Inference happens inside the Watch app
# process: no backend, Ollama, Docker, paired iPhone or internet is consulted.
#
# Exit codes: 0 verified PASS, 1 a checked condition failed, 2 environmental
# blocker (no simulator or runtime available), 3 wrong usage.
set -uo pipefail
cd "$(dirname "$0")/.."

BUNDLE="ph.vanguard.ios.watch"
ARTIFACT="qwen-diagnostic.json"
failures=()
notes=()

line() { printf '%s\n' "$*"; }

record() { # record <PASS|FAIL|UNVERIFIED> <label> <detail>
  local status="$1" label="$2" detail="${3:-}"
  case "$status" in
    PASS) line "  $label: PASS${detail:+ — $detail}" ;;
    FAIL) line "  $label: FAIL${detail:+ — $detail}"; failures+=("$label") ;;
    *)    line "  $label: UNVERIFIED${detail:+ — $detail}"; notes+=("$label") ;;
  esac
}

# Replays the app-written checks, so displayed results come from the inference
# run itself rather than from this script's own expectations.
checks() { # checks <evidence-json> ; prints "status<TAB>label<TAB>detail" lines
  python3 - "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
cases = r.get("cases", [])

def rec(status, label, detail=""):
    print(f"{status}\t{label}\t{detail}")

rec("PASS" if r.get("status") == "PASS" else "FAIL", "Local Inference Executed", str(r.get("status")))
rec("PASS" if r.get("model") == "Qwen3-0.6B" else "FAIL", "Model Initialized", str(r.get("model")))
rec("PASS" if r.get("execution") == "Native Watch Application" else "FAIL",
    "Execution location", str(r.get("execution")))
rec("PASS" if r.get("backendDependency") == "NONE" else "FAIL", "Backend Dependency", str(r.get("backendDependency")))
rec("PASS" if r.get("iphoneDependency") == "NONE" else "FAIL", "iPhone Dependency", str(r.get("iphoneDependency")))
rec("PASS" if len(cases) >= 7 else "FAIL", "Repeated inference requests", f"{len(cases)} distinct requests")
rec("PASS" if all(c.get("generatedTokens", 0) > 0 for c in cases) else "FAIL",
    "Token generation status", "every request generated output tokens")
rec("PASS" if all(c.get("inferenceExecuted") for c in cases) else "FAIL",
    "Native inference per request", "all requests ran the local engine")
rec("PASS" if any("Tokenizer initialized" in e for e in r.get("pipelineLog", [])) else "FAIL",
    "Tokenizer Initialized", "embedded GGUF vocabulary")
rec("PASS" if any("Model loaded" in e for e in r.get("pipelineLog", [])) else "FAIL",
    "Weights loaded in Watch process", "")
rec("PASS" if not r.get("failures") else "FAIL", "Runtime errors", str(r.get("failures"))[:120])

echo_case = next((c for c in cases if c["name"] == "echo"), None)
if echo_case and "VANGUARD_QWEN_READY" in (echo_case.get("output") or ""):
    rec("PASS", "Echo Test", (echo_case["output"] or "")[:70])
else:
    rec("FAIL", "Echo Test", (echo_case or {}).get("output", "case missing")[:70])

uniq = next((c for c in cases if c["name"].startswith("unique-echo-")), None)
if uniq:
    marker = uniq["name"].replace("unique-echo-", "")
    out = uniq.get("output") or ""
    rec("PASS" if marker in out else "FAIL", "Unique-run echo (anti-cache/hardcode)", f"{marker} -> {out[:60]}")
else:
    rec("FAIL", "Unique-run echo (anti-cache/hardcode)", "case missing")

sem = next((c for c in cases if c["name"] == "semantic-generation"), None)
if sem:
    out = (sem.get("output") or "").strip()
    low = out.lower()
    prompt_fragment = "organ that pumps blood is the"
    # A genuine completion answers the question and is not a verbatim prompt copy.
    answers = "heart" in low
    copied = low.strip(" .*") == prompt_fragment
    rec("PASS" if answers and not copied and sem.get("generatedTokens", 0) > 0 else "FAIL",
        "Semantic Generation Test", out[:70])
else:
    rec("FAIL", "Semantic Generation Test", "case missing")
PY
}

replay() { # replay <evidence-json>
  local row status label detail
  while IFS=$'\t' read -r status label detail; do
    [[ -n "$label" ]] || continue
    record "$status" "$label" "$detail"
  done < <(checks "$1")
}

line "========================================"
line "VANGUARD WATCH QWEN DIAGNOSTIC"
line "========================================"

# --- 1. Xcode environment -----------------------------------------------------
if xcodebuild -version > /dev/null 2>&1; then
  record PASS "Xcode environment" "$(xcodebuild -version 2>/dev/null | head -2 | tr '\n' ' ')"
else
  record FAIL "Xcode environment" "xcodebuild is not runnable"
fi
if xcrun simctl list runtimes available 2>/dev/null | grep -q "watchOS"; then
  record PASS "watchOS runtime present"
else
  record FAIL "watchOS runtime present"
  line ""; line "FINAL RESULT:"; line "BLOCKED — no watchOS simulator runtime on this machine."
  exit 2
fi

# --- 2. Model artifact -------------------------------------------------------
model_out="$(node -e 'require("./hub/model").verifyModel().then(m=>console.log(m.model,m.sizeBytes,m.sha256)).catch(e=>{console.error(e.message);process.exitCode=1;})' 2>&1)"
if [[ $? -eq 0 ]]; then
  record PASS "Model Located (pinned GGUF + manifest + SHA-256)" "$(echo "$model_out" | head -1)"
else
  record FAIL "Model Located (pinned GGUF + manifest + SHA-256)" "$(echo "$model_out" | head -1)"
fi

# --- 3. Simulator selection and boot ----------------------------------------
device=""; device_name=""
while IFS= read -r entry; do
  candidate="$(echo "$entry" | grep -oE '\([0-9A-Fa-f-]{36}\)' | tr -d '()')"
  [[ -z "$candidate" ]] && continue
  name="$(echo "$entry" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*\([0-9A-Fa-f-]{36}\).*//')"
  case "$name" in
    *"Watch"*) device="$candidate"; device_name="$name"; break ;;
  esac
done < <(xcrun simctl list devices available 2>/dev/null | sed -n '/-- watchOS/,/^-- /p' | grep -F '(')
if [[ -z "$device" ]]; then
  record FAIL "Watch Simulator" "no available Apple Watch simulator"
  line ""; line "FINAL RESULT:"; line "BLOCKED — no Apple Watch simulator is available."
  exit 2
fi
xcrun simctl boot "$device" > /dev/null 2>&1
xcrun simctl bootstatus "$device" -b > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
  record PASS "Simulator booted" "$device_name"
else
  record FAIL "Simulator booted" "$device_name"
fi

# --- 4. Build ----------------------------------------------------------------
build_log="$(mktemp -t vanguard-watch-build.XXXXXX)"
xcodebuild -project watch/apple/Vanguard.xcodeproj -scheme VanguardWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath watch/apple/DerivedData CODE_SIGNING_ALLOWED=NO build > "$build_log" 2>&1
if [[ $? -eq 0 ]]; then
  record PASS "Watch App Build"
else
  record FAIL "Watch App Build" "$(grep -m1 'error:' "$build_log" | head -c 160)"
fi
if grep -q "Verify pinned Qwen" "$build_log" && grep -q "BUILD SUCCEEDED" "$build_log"; then
  record PASS "Pinned weights verified during build"
else
  record FAIL "Pinned weights verified during build"
fi
app="watch/apple/DerivedData/Build/Products/Debug-watchsimulator/VanguardWatch.app"
if [[ -d "$app" ]]; then record PASS "VanguardWatch.app produced"; else record FAIL "VanguardWatch.app produced"; fi
if ls "$app"/qwen3-0.6b/manifest.json > /dev/null 2>&1; then
  record PASS "Model bundled inside Watch app"
else
  record FAIL "Model bundled inside Watch app"
fi

# --- 5. Install + launch -----------------------------------------------------
if xcrun simctl install "$device" "$app" > /dev/null 2>&1; then
  record PASS "Watch App Install"
else
  record FAIL "Watch App Install"
  line ""; line "FINAL RESULT:"; line "FAIL — VanguardWatch could not be installed."
  exit 1
fi
container="$(xcrun simctl get_app_container "$device" "$BUNDLE" data 2>/dev/null)"
if [[ -n "$container" ]]; then record PASS "App container resolved"; else record FAIL "App container resolved"; fi

# A fresh launch must produce a new artifact; a stale PASS cannot satisfy this run.
previous="$(stat -f %m "$container/Documents/$ARTIFACT" 2>/dev/null || echo 0)"
if xcrun simctl launch --terminate-running-process "$device" "$BUNDLE" --qwen-diagnostic > /dev/null 2>&1; then
  record PASS "Watch App Launch (simctl returned a pid)"
else
  record FAIL "Watch App Launch (simctl returned a pid)"
fi

line ""
line "Waiting for native inference (first load parses a 378 MiB GGUF)…"
ready=""
for _ in $(seq 1 240); do
  current="$(stat -f %m "$container/Documents/$ARTIFACT" 2>/dev/null || echo 0)"
  if [[ "$current" -gt "$previous" ]]; then ready=1; break; fi
  sleep 2
done

line ""
if [[ -z "$ready" ]]; then
  record FAIL "Local Inference Executed" "no fresh $ARTIFACT written; inspect simulator crash logs"
else
  replay "$container/Documents/$ARTIFACT"
  line ""
  line "Inference Execution:"
  line "  Device: $device_name ($device)"
  python3 - "$container/Documents/$ARTIFACT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("  Process:", r.get("device"))
print(f"  Inference Duration: {r.get('totalDurationSeconds', 0):.3f}s total for {len(r.get('cases', []))} requests")
print("  Run ID:", r.get("runID"))
PY
  line ""
  line "Actual generated outputs (from the Watch app):"
  python3 - "$container/Documents/$ARTIFACT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for c in r.get("cases", []):
    print(f"  [{c['name']}] {c.get('inputTokens')} in / {c.get('generatedTokens')} out, {c.get('durationSeconds', 0):.3f}s")
    print(f"    prompt:  {c.get('input', '')[:100]}")
    print(f"    output:  {(c.get('output') or c.get('error') or '')[:170]}")
PY
  line ""
  line "Pipeline log (in-process, [VANGUARD_QWEN_WATCH]):"
  python3 - "$container/Documents/$ARTIFACT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for entry in r.get("pipelineLog", []):
    print("   ", entry[:150])
PY
  line ""
  line "Process liveness after inference:"
  sleep 2
  pid="$(xcrun simctl spawn "$device" launchctl list 2>/dev/null | grep "$BUNDLE" | awk '{print $1}' | head -1)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    record PASS "Application process remains alive" "pid $pid"
  else
    record FAIL "Application process remains alive" "process exited after inference"
  fi
fi

# --- 6. Offline isolation ----------------------------------------------------
line ""
line "Offline verification:"

# Record which inference-capable services exist before touching anything, so the
# restoration step and the report are honest about what this run changed.
stopped_projects=()
stopped_ollama=()

hub_up() { [[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:3000/api/ai/health 2>/dev/null)" == "200" ]]; }
ollama_up() { curl -s -o /dev/null -m 2 http://127.0.0.1:11434/api/tags 2>/dev/null; }

for project in hub vanguard; do
  if docker compose -p "$project" ps 2>/dev/null | grep -qE "ollama|hub"; then stopped_projects+=("$project"); fi
done
if ollama_up; then stopped_ollama=("yes"); fi

restore() {
  local restored=()
  # The Watch app never reads host configuration, so it needs no restored service.
  for project in "${stopped_projects[@]}"; do
    docker compose -p "$project" start > /dev/null 2>&1 && restored+=("$project")
  done
  (( ${#stopped_projects[@]} > 0 && ${#restored[@]} == 0 )) && line "  NOTE: could not restart ${stopped_projects[*]} automatically"
  return 0
}
trap restore EXIT

for project in "${stopped_projects[@]}"; do
  docker compose -p "$project" stop > /dev/null 2>&1 && line "  Stopped project: $project"
done
if (( ${#stopped_ollama[@]} > 0 )); then
  pkill -f "ollama serve" > /dev/null 2>&1 && line "  Stopped: Mac Ollama"
fi

if hub_up; then
  record FAIL "Backend absent during run" "a hub answered /api/ai/health after isolation"
elif ollama_up; then
  record FAIL "Ollama absent during run" "Mac Ollama still answers after isolation"
else
  record PASS "Backend and Ollama stopped" "no hub and no Ollama reachable"
fi

# Relaunch cold, with every inference-capable service stopped: a second full model
# load that still generates tokens shows the Watch process is self-sufficient and
# nothing was cached in a warm helper on the Mac.
previous2="$(stat -f %m "$container/Documents/$ARTIFACT" 2>/dev/null || echo 0)"
xcrun simctl terminate "$device" "$BUNDLE" > /dev/null 2>&1
xcrun simctl launch --terminate-running-process "$device" "$BUNDLE" --qwen-diagnostic > /dev/null 2>&1
cold=""
for _ in $(seq 1 180); do
  current="$(stat -f %m "$container/Documents/$ARTIFACT" 2>/dev/null || echo 0)"
  if [[ "$current" -gt "$previous2" ]]; then cold=1; break; fi
  sleep 2
done
if [[ -n "$cold" ]]; then
  while IFS=$'\t' read -r status label detail; do
    [[ -n "$label" ]] && record "$status" "$label" "$detail"
  done < <(python3 - "$container/Documents/$ARTIFACT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
cases = r.get("cases", [])
ok = r.get("status") == "PASS" and cases and all(c.get("generatedTokens", 0) > 0 for c in cases)
detail = ("%d requests generated tokens with backend/Ollama stopped (run %s)" % (len(cases), r.get("runID"))
          if ok else str(r.get("failures"))[:120])
print(("PASS\tOffline cold-relaunch inference\t%s" if ok else "FAIL\tOffline cold-relaunch inference\t%s") % detail)
PY
)
else
  record FAIL "Offline cold-relaunch inference" "no fresh evidence after relaunch"
fi
line ""
line "  Simulator success is NOT physical Apple Watch evidence: memory limits,"
line "  battery, thermals and background behaviour still require real hardware."

# --- 7. Verdict --------------------------------------------------------------
line ""
line "========================================"
line "FINAL RESULT:"
if (( ${#failures[@]} > 0 )); then
  line "FAIL — ${#failures[@]} condition(s) failed: ${failures[*]}"
  line "========================================"
  exit 1
elif (( ${#notes[@]} > 0 )); then
  line "PASS — QWEN EXECUTED IN WATCH SIMULATOR (unverified: ${notes[*]})"
  line "========================================"
  exit 0
else
  line "PASS — QWEN EXECUTED IN WATCH SIMULATOR"
  line "========================================"
  exit 0
fi
