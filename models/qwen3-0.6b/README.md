# Repository-managed Qwen3-0.6B

Actual `qwen3-0.6b-q4_k_m.gguf` weights are tracked with Git LFS. This is the
Unsloth Q4_K_M conversion of the official [Qwen3-0.6B model](https://huggingface.co/Qwen/Qwen3-0.6B),
not an official Qwen-published quantization. Conversion revision, file bytes,
SHA-256, source config revision, license and runtime pins are in `manifest.json`.
The GGUF embeds tokenizer vocabulary, special tokens, architecture metadata and
chat template. `config.json` preserves the upstream configuration for reference.
Inference requires no Transformers/tokenizer downloads or cloud services.

Docker startup needs Git and Docker Compose, not host Ollama or Git LFS. A one-shot
initializer copies verified checkout weights or downloads this exact manifest URL
when only an LFS pointer is present, checks the size/header/SHA-256, and atomically
installs it into a persistent weights volume. Ollama imports it on its internal-only
network and preserves imported blobs in a separate volume. Download failure never
promotes readiness; inspect `model-init` logs and retry initial setup.

For Apple packaging, run `scripts/qwen-setup.sh --model-only` with Node 22+ while
online if weights are absent. Then use Xcode/CMake and `scripts/qwen-native-build.sh`.
The app build checks SHA-256 before packaging the model. iOS/watchOS runtime never
downloads a model and never needs Docker or host Ollama. Native CPU build tooling
currently targets Apple Silicon hosts and arm64/arm64_32 Apple targets; Intel hosts
and physical execution remain unverified. Optional host Ollama developers can run
`scripts/qwen-setup.sh host` after starting Ollama 0.11.4.

Attribution: Qwen team, Apache-2.0 (full upstream `LICENSE` included); GGUF conversion
by [Unsloth](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/tree/50968a4468ef4233ed78cd7c3de230dd1d61a56b).
Inference engine: ggml-org llama.cpp, MIT (vendored license and exact revision in
`vendor/llama.cpp/VANGUARD.md`). See `docs/QWEN_INTEGRATION.md` for platform limits
and performed verification. These are synthetic development workflows, not a
validated clinical system.
