#!/bin/sh
set -eu
cd /models
# Check artifact integrity on every restart before importing the local file.
tr -d '\r' < checksums.sha256 | sha256sum --check -
tr -d '\r' < Modelfile | sed 's#^FROM \./#FROM /models/#' > /tmp/Modelfile
ollama serve &
runtime_pid=$!
trap 'kill "$runtime_pid" 2>/dev/null || true' EXIT INT TERM
ready=0
for attempt in $(seq 1 60); do
  if ollama list >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$runtime_pid" 2>/dev/null || { echo 'Ollama startup failed' >&2; exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { echo 'Ollama startup timed out' >&2; exit 1; }
ollama create qwen3:0.6b -f /tmp/Modelfile
wait "$runtime_pid"
