#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v git-lfs >/dev/null || git lfs version >/dev/null
# Explicit setup is the only network-capable model step. Runtime never pulls.
git lfs install --local
git lfs pull --include='models/**/*.gguf'
node -e 'require("./hub/model").verifyModel().then(m => console.log("Verified", m.model, m.sha256)).catch(e => {console.error(e.message);process.exitCode=1;})'
command -v ollama >/dev/null || { echo 'Install Ollama 0.11.4 during initial setup, then run ollama serve.' >&2; exit 1; }
(cd models/qwen3-0.6b && ollama create qwen3:0.6b -f Modelfile)
echo 'Local Qwen imported. No runtime download is required.'
