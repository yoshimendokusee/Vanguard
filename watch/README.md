# Vanguard-Wrist watch app

See the [project README](../README.md) for setup, the Vosk model caveat, and the demo script.


## Native Apple Qwen apps

The existing Flutter/Wear OS implementation stays intact. `apple/Vanguard.xcodeproj`
now contains VanguardPhone and VanguardWatch SwiftUI app targets using repository
Qwen weights and a shared CPU llama.cpp library. Run `../scripts/qwen-native-build.sh`
from this directory (or `./scripts/qwen-native-build.sh` from the repository root)
after Git LFS setup. See `../docs/QWEN_INTEGRATION.md` for packaging, schemes,
independent simulator generation, durable fallback and hardware limitations.
Watch speech recognition remains unimplemented; recorded audio can be queued for
on-device iPhone speech/Qwen processing. Physical pairing/STT are unverified.
