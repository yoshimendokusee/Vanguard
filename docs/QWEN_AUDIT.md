# Qwen integration audit — 2026-10-09, before implementation

Baseline: c69996e, clean worktree on Ticket/-Qwen-echo. Inspected tracked application,
configuration, contract, migration and test files; no persistent patient database
opened. Existing paths stay in place.

| Component | Existing implementation | Gap |
| --- | --- | --- |
| Hub | Express modular monolith; `ai.js` calls local Ollama, bounds request time, validates enums/evidence; deterministic `risk.js` | No weights, local import, checksum validation or execution-based health. URL override ignored; prefix model-name match can falsely report ready. |
| Hospital UI | Plain HTML/JS, same-origin extraction panel, SSE/polling | Manual review checkbox required for saving; save truncates originals to 1,000 characters, discards processing/evidence/provenance; early errors leave buttons disabled; extraction can be applied to changed input. |
| Hospital storage | SQLite schema v2; transactional intake, original submissions, explicit encounters, immutable idempotent revisions and corrections | Existing extraction revisions can persist Qwen output without a migration; routes do not yet connect inference to a selected report. |
| Watch prototype | Flutter/Wear OS; separately provisioned Vosk STT, deterministic Taglish parser, SQLite-first capture, bounded LAN queue and validated ACKs | No on-device Qwen; AI service is an optional hub client and is not capture logic. Preserve working Android code. |
| Apple library | Swift request/response types; iPhone on-device Speech; recovery processor with repository/processor ports and cancellation tests | No native app targets, Qwen runtime, model assets, durable native repository or Watch Connectivity implementation. Speech.framework is absent on watchOS. |
| Docker | Hospital API/dashboard image, both Compose entry points share hub/data | No runtime service or model packaging. Preserve hub service/data paths; prepare images while online before offline starts. |
| Tests/CI | Hub unit/HTTP/storage upgrades; Dart parser/queue/cloud/AI tests; Swift contract/recovery tests | Mock Ollama tests prove contracts only. No independent native token generation, memory measurements or real offline inference evidence. |

Implementation reaches model packaging/setup, `hub/ai.js`, server routes, dashboard,
AI regression tests, both Compose entry points, native library/app/build/smoke paths,
verification scripts, API and architecture documentation. Use existing report revisions
and deterministic provisional rules. Generated claims stay unverified; model matching
text cannot establish clinical truth. Capture is durable before inference/transport;
never overwrite original speech or mark a relay as hospital delivery.

Required runtime: locally imported GGUF with embedded tokenizer/config/chat template,
Ollama on hospital host/container; native CPU llama.cpp on Apple platforms. Native
watchOS compilation and simulator generation are independent checks, never physical
watch memory/battery evidence. Hardware and offline Watch STT require explicit evidence.
