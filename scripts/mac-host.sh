#!/usr/bin/env bash
# Builds and opens the Mac development host for the Vanguard Watch UI as a real .app bundle.
# macOS asks for microphone and speech permission on behalf of the responsible app. A bare executable started from a
# terminal is attributed to the terminal, which has no usage description, and macOS would kill it. A bundle is its own app.
# Usage: scripts/mac-host.sh [--fresh] [--hub URL] [--model DIR] [--size 41|45|49] [--submit "text"]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/watch/apple"
swift build --product VanguardWatchMac
app="$PWD/.build/VanguardWatchMac.app"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp .build/debug/VanguardWatchMac "$app/Contents/MacOS/VanguardWatchMac"
# SwiftPM resources (the terminology pack and database migrations) live in a bundle that Bundle.module looks up in Resources.
cp -R .build/debug/VanguardApple_VanguardApple.bundle "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>VanguardWatchMac</string>
  <key>CFBundleIdentifier</key><string>ph.vanguard.watchmac.dev</string>
  <key>CFBundleName</key><string>Vanguard Watch (Mac dev host)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Record a synthetic test report to try the Vanguard Watch workflow on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribe the test recording on this Mac without network recognition.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
args=("$@")
if [[ ! " ${args[*]} " =~ " --model " ]]; then args+=(--model "$root/models/qwen3-0.6b"); fi
open -n "$app" --args "${args[@]}"
echo "Opened $app"
