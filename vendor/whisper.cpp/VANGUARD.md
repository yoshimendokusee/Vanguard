# Vanguard integration

This source is vendored from `ggml-org/whisper.cpp` commit
`d1be6fde11ac6e0407606b4e42fe72d34add8037` (version 1.9.5-dev). Only the
CMake build files, public headers, whisper sources, and ggml sources are kept.
The Watch build uses CPU-only slices; `ggml-cpu.cpp` reads Watch memory through
`hw.memsize` because watchOS does not provide `_SC_PHYS_PAGES`.

Upstream project and license: https://github.com/ggml-org/whisper.cpp
