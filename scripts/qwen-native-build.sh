#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
output="$root/watch/apple/.native"
mkdir -p "$output/headers"
cp vendor/llama.cpp/include/llama.h vendor/llama.cpp/ggml/include/*.h "$output/headers/"
cat > "$output/headers/module.modulemap" <<'MAP'
module llama {
  header "llama.h"
  link "c++"
  export *
}
MAP
libraries=()
for platform in macos iphoneos iphonesimulator watchos watchsimulator; do
  case "$platform" in
    macos) system=Darwin; sdk=macosx; arch=arm64; minimum=14.0 ;;
    iphone*) system=iOS; sdk="$platform"; arch=arm64; minimum=17.0 ;;
    watchos) system=watchOS; sdk="$platform"; arch=arm64_32; minimum=10.0 ;;
    watchsimulator) system=watchOS; sdk="$platform"; arch=arm64; minimum=10.0 ;;
  esac
  build="$output/build-$platform"
  cmake -S vendor/llama.cpp -B "$build" -G Xcode \
    -DCMAKE_SYSTEM_NAME="$system" -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
    -DCMAKE_C_FLAGS="-include $root/watch/apple/WatchCompatibility.h" \
    -DCMAKE_CXX_FLAGS="-include $root/watch/apple/WatchCompatibility.h" \
    -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DGGML_METAL=OFF -DGGML_BLAS=OFF -DGGML_ACCELERATE=OFF -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF -DGGML_LLAMAFILE=OFF -DGGML_CPU_KLEIDIAI=OFF \
    -DLLAMA_BUILD_COMMIT=a7a98e0 -DLLAMA_BUILD_NUMBER=6500
  cmake --build "$build" --config Release --parallel 4 --target llama -- CODE_SIGNING_ALLOWED=NO -quiet
  archives=()
  while IFS= read -r file; do archives+=("$file"); done < <(find "$build" -name '*.a' -path '*/Release*/*')
  ((${#archives[@]} > 0)) || { echo "No native archives for $platform" >&2; exit 1; }
  libtool -static -o "$output/libllama-$platform.a" "${archives[@]}"
  libraries+=(-library "$output/libllama-$platform.a" -headers "$output/headers")
done
# xcodebuild refuses to overwrite a framework; preserve it until all slices build.
xcodebuild -create-xcframework "${libraries[@]}" -output "$output/llama-staging-$$.xcframework"
if [[ -d "$output/llama.xcframework" ]]; then mv "$output/llama.xcframework" "$output/llama-previous-$$.xcframework"; fi
mv "$output/llama-staging-$$.xcframework" "$output/llama.xcframework"
echo 'Native CPU llama.cpp slices built; device execution still needs hardware.'
