#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$root/watch/apple/.native"
rm -rf "$output/whisper-headers"
mkdir -p "$output/whisper-headers" "$output/whisper-cmake"
cp "$root/vendor/whisper.cpp/include/whisper.h" "$output/whisper-headers/"
mkdir -p "$output/whisper-headers/Modules"
cat > "$output/whisper-headers/Modules/module.modulemap" <<'MAP'
framework module whisper {
  header "whisper.h"
  link "c++"
  export *
}
MAP
cat > "$output/whisper-cmake/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(VanguardWhisper C CXX)
add_subdirectory("$root/vendor/whisper.cpp" whisper)
EOF

frameworks=()
platforms=${WHISPER_PLATFORMS:-"watchos watchsimulator"}
for platform in $platforms; do
  case "$platform" in
    watchos) system=watchOS; sdk=watchos; arch=arm64_32; minimum=10.0 ;;
    watchsimulator) system=watchOS; sdk=watchsimulator; arch=arm64; minimum=10.0 ;;
    *) echo "Unsupported Whisper platform: $platform" >&2; exit 1 ;;
  esac
  build="$output/whisper-build-$platform"
  cmake -S "$output/whisper-cmake" -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
    -DCMAKE_C_FLAGS="-include $root/watch/apple/WatchCompatibility.h" \
    -DCMAKE_CXX_FLAGS="-include $root/watch/apple/WatchCompatibility.h" \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_IS_DEV=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_CURL=OFF -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF \
    -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_LLAMAFILE=OFF -DGGML_CPU_KLEIDIAI=OFF
  cmake --build "$build" --config Release --parallel 4 --target whisper -- CODE_SIGNING_ALLOWED=NO -quiet
  archives=()
  while IFS= read -r file; do archives+=("$file"); done < <(find "$build" -name '*.a' -path '*/Release*/*')
  ((${#archives[@]} > 0)) || { echo "No Whisper archives for $platform" >&2; exit 1; }
  libtool -static -o "$output/libwhisper-$platform.a" "${archives[@]}"
  framework="$output/$platform/whisper.framework"
  rm -rf "$output/$platform"
  mkdir -p "$framework/Headers" "$framework/Modules"
  cp "$output/whisper-headers/"*.h "$framework/Headers/"
  cp "$output/whisper-headers/Modules/module.modulemap" "$framework/Modules/"
  cp "$output/libwhisper-$platform.a" "$framework/whisper"
  if [[ "$platform" == watchos ]]; then supported=WatchOS; else supported=WatchSimulator; fi
  cat > "$framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>whisper</string>
  <key>CFBundleIdentifier</key><string>ph.vanguard.whisper</string>
  <key>CFBundleName</key><string>whisper</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
  <key>MinimumOSVersion</key><string>10.0</string>
</dict></plist>
EOF
  frameworks+=(-framework "$framework")
done

staging="$output/whisper-staging-$$.xcframework"
xcodebuild -create-xcframework "${frameworks[@]}" -output "$staging"
if [[ -d "$output/whisper.xcframework" ]]; then mv "$output/whisper.xcframework" "$output/whisper-previous-$$.xcframework"; fi
mv "$staging" "$output/whisper.xcframework"
echo 'CPU-only whisper.cpp Watch slices built; physical Watch inference still needs device validation.'
