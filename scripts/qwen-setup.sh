#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Native packaging needs verified weights, never Docker or a host Ollama server.
mode="${1:-host}"
[[ "$mode" = host || "$mode" = --model-only ]] || { echo 'Use host or --model-only' >&2; exit 1; }
node -e 'require("./hub/provision-model").provisionModel("models/qwen3-0.6b", "models/qwen3-0.6b").catch(e => {console.error(e.message);process.exitCode=1;})'
node -e 'require("./hub/model").verifyModel().then(m => console.log("Verified", m.model, m.sha256)).catch(e => {console.error(e.message);process.exitCode=1;})'
[[ "$mode" = --model-only ]] && exit 0
command -v ollama >/dev/null || { echo 'Install Ollama 0.11.4 during initial setup, then run ollama serve.' >&2; exit 1; }
(cd models/qwen3-0.6b && ollama create qwen3:0.6b -f Modelfile)
echo 'Local Qwen imported. No runtime download is required.'
