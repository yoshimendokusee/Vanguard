Vendored core from ggml-org/llama.cpp b6500, commit a7a98e0fffed794396b3fbad4dcdbbc184963645.
Source tar SHA256: 4d78e6aa4a9124b58dff994416525294fbab2990fe905a640d4cbd26bf563a31.
Only runtime/include/ggml/CMake/license files retained; source files are unchanged except for removal of extra EOF blank lines and the watchOS memory-query guard in ggml/src/ggml-cpu/ggml-cpu.cpp.
Tools, examples, documentation and training assets omitted; build with LLAMA_BUILD_COMMON/TESTS/TOOLS/EXAMPLES/SERVER=OFF.
Apple builds force-include watch/apple/WatchCompatibility.h to provide BSD aliases omitted by the watchOS SDK. CPU-only slices use no Metal, Accelerate or runtime network downloader.
