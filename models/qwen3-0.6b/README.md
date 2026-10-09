# Repository-managed Qwen3-0.6B

Actual `qwen3-0.6b-q4_k_m.gguf` weights are tracked with Git LFS. This is the
Unsloth Q4_K_M conversion of the official [Qwen3-0.6B model](https://huggingface.co/Qwen/Qwen3-0.6B),
not an official Qwen-published quantization. Conversion revision, file bytes,
SHA-256, source config revision, license and runtime pins are in `manifest.json`.
The GGUF embeds tokenizer vocabulary, special tokens, architecture metadata and
chat template. `config.json` preserves the upstream configuration for reference.
Inference requires no Transformers/tokenizer downloads or cloud services.

Install Git LFS, Node 22+, Ollama 0.11.4 and (Apple builds) Xcode/CMake during
initial setup. From the repository root, run `scripts/qwen-setup.sh` with local
`ollama serve` running. It retrieves Git LFS objects explicitly, verifies actual
weights (rejecting pointers), then imports this file as `qwen3:0.6b`. Never use
`ollama pull` at application startup. `scripts/qwen-echo.sh` validates the repository
artifact and imported blob identity before requesting real generated tokens.

Docker binds this directory read-only and imports the same artifact on startup.
Apple app resource folders package the same bytes; run `scripts/qwen-native-build.sh`
to prepare the local CPU XCFramework before opening `watch/apple/Vanguard.xcodeproj`.
No external Swift package or native model download occurs at runtime.

Attribution: Qwen team, Apache-2.0 (full upstream `LICENSE` included); GGUF conversion
by [Unsloth](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/tree/50968a4468ef4233ed78cd7c3de230dd1d61a56b).
Inference engine: ggml-org llama.cpp, MIT (vendored license and exact revision in
`vendor/llama.cpp/VANGUARD.md`). See `docs/QWEN_INTEGRATION.md` for platform limits
and performed verification. These are synthetic development workflows, not a
validated clinical system.
