# Vanguard Qwen3-0.6B integration report

Observed on 2026-10-09 on macOS arm64 with Xcode 27.0, iOS/watchOS SDK 27.0,
and simulator runtimes 26.5. Only synthetic inputs and isolated temporary/simulator
databases or new Docker volumes were used. Existing hospital data was not opened,
reset or used for demos. This report records local checks; hosted CI is a separate
PR requirement. **Implementation is available for review; full physical-device
and cross-platform offline acceptance remains BLOCKED.**

## Audit and implementation

The [pre-change audit](QWEN_AUDIT.md) found a functioning Express/SQLite hub,
hospital dashboard, Flutter/Wear OS capture/queue, optional hospital AI client,
and Apple contract/STT/recovery library. There were no native Apple app targets,
local weights, native Qwen runtime or execution-based health. Existing paths,
frameworks, applied migrations and deterministic provisional rules were retained.

The proposed `models/qwen3-0.6b/` directory is suitable **artifact storage**. The
system also needs native Apple inference, hospital inference, and durable capture,
extraction and receipt storage. See [the implemented design and setup](QWEN_INTEGRATION.md).

- **Model:** official-source Qwen3-0.6B, Unsloth Q4_K_M GGUF conversion at
  `50968a4468ef4233ed78cd7c3de230dd1d61a56b`, Apache-2.0. This is not an official
  Qwen-published quantization. Embedded GGUF tokenizer/template need no downloads.
- **Repository artifact:** `models/qwen3-0.6b/qwen3-0.6b-q4_k_m.gguf`,
  396,705,472 bytes; SHA-256
  `ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a`.
  Actual bytes exist locally and are tracked through Git LFS. Explicit initial LFS
  setup is required; integrity checks reject pointers, corruption and missing files.
- **Hospital:** local Ollama 0.11.4 imports those exact bytes. A pinned Docker image,
  read-only model mount and internal inference network require no runtime pull.
  Execution-based health checks verify identity, positive tokens and normal completion.
- **Apple:** vendored llama.cpp b6500 CPU runtime; local XCFramework slices for
  macOS, iOS device/simulator and watchOS device/simulator. SwiftUI apps package
  model resources, use actor-isolated inference, bounded generation and durable SQLite.
- **Workflow:** preserve original first, extract unverified claims with source
  excerpts and provenance, retain pending work, and accept only scoped hospital ACKs.
  Web extraction appends an immutable revision on the selected persisted encounter.
  Watch Connectivity queues retained fallback jobs/results; physical behavior is unverified.

## Final verification matrix

| Component | Status | Evidence and boundary |
| --- | --- | --- |
| Repository model | PASS | Real 396,705,472-byte GGUF; Git index contains its exact LFS pointer/object identity |
| Model integrity | PASS | SHA-256, magic, size and pinned manifest checks; native and backend reject bad artifacts |
| Ollama inference | PASS | Real local echo output `VANGUARD_QWEN_OK`, 9 generated tokens, normal completion and exact artifact identity |
| Docker integration | PASS | Hub image built; both Compose entry points validated; actual local model imported and generated inside isolated containers |
| Backend API | PASS | Fresh execution-based health, extraction on persisted original, encounter preservation and idempotent replay |
| Web integration | PASS | Actual rendered button invoked Qwen and appended revision 3 after main integration; original, source excerpts, provenance and provisional Unassessed remained visible |
| iOS native inference | PASS in simulator; physical BLOCKED | Production app used its own packaged GGUF/native engine and persisted actual clinical extraction; unsigned device target built |
| watchOS inference | PASS in simulator; physical BLOCKED | Independent production Watch app generated tokens and preserved/persisted original; actual watchOS arm64_32 target built |
| Watch fallback | BLOCKED on paired hardware | Recovery/storage regression passes; real WCSession disconnect, background transfer and reconnect have no physical evidence |
| Offline operation | PASS for Docker and native macOS; full acceptance BLOCKED | Actual network denial plus generation; Docker restarts retain rows; physical Apple restarts/STT and offline LAN with real devices untested |
| Patient persistence | PASS for synthetic records | Immutable originals, evidence/provenance, explicit encounter, retries, SQLite reopen, scoped native ACK and Docker restart comparison |

## Commands and exact results

| Command/check | Result |
| --- | --- |
| `cd hub && npm ci && npm test` | PASS: final suite 52 passed, 0 failed, 0 skipped; includes a real local Ollama live check |
| `cd watch && flutter pub get && flutter analyze && flutter test` | PASS: analysis found no issues; 103 tests passed, including populated upgrade and intentional rollback-failure checks |
| `./scripts/qwen-native-build.sh` | PASS: all five CPU slices built and local XCFramework created |
| `./scripts/qwen-echo.sh` (also executed by aggregate check) | PASS: actual marker output, 9 tokens, warm request 821.1 ms, 90.2 tokens/s |
| `QWEN_TEST_HUB_URL=… QWEN_IOS_SIM=… QWEN_WATCH_SIM=… VANGUARD_LIVE_MODEL_DIR=… VANGUARD_TEST_HUB_URL=… ./scripts/qwen-verify.sh` | Simulator/backend/native checks PASS; exit **2** honestly records physical coverage BLOCKED |
| `xcrun swift test --package-path watch/apple` with real model and synthetic hub environment | PASS: 11 tests, 0 failures, 0 skips; actual native generation, timeout, durable extraction, native outbox → hospital API → scoped ACK |
| Native XCTest bundle under `sandbox-exec -p '(version 1)(allow default)(deny network*)'`, `VANGUARD_LIVE_MODEL_DIR=… VANGUARD_REQUIRE_NETWORK_DENIED=1` | PASS: 11 tests; real HTTPS egress rejected, actual native generation completed with no network permission |
| `xcodebuild … -scheme VanguardPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | PASS: latest unsigned iPhone and embedded Watch device build succeeded; compilation is not device inference evidence |
| `xcodebuild … -scheme VanguardWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build` | PASS: unsigned Watch SDK/arm64_32 build; no hardware execution claim |
| `docker compose config --quiet` and `docker compose -f hub/docker-compose.yml config --quiet` | PASS; isolated QA Compose also validated |
| `docker build -t vanguard-qwen-qa:local hub` | PASS |
| `docker run --rm --network none --env DB_PATH=:memory: … vanguard-qwen-qa:local npm test` with read-only docs/watch/model mounts | PASS: 51 passed, 0 failed, **1 skipped** because real Ollama is unreachable in this deliberately isolated regression container |
| `./scripts/qwen-offline-test.sh` | Docker acceptance PASS; exit **2** for physical acceptance BLOCKED. External egress denied, actual extraction stored, both containers restarted, reports compared unchanged |
| `node --test .github/scripts/validate-repository.test.js` | PASS: 6 tests; generated frameworks/app bundles excluded from fixture copies |
| `node .github/scripts/validate-repository.js`, shell/Node syntax and actionlint | PASS |
| Staged text secret-pattern scan, no database/config/signing files, Git diff whitespace check | PASS; full hosted secret scan remains a separate CI check |

The final offline Docker project was `vanguard-qwen-offline-1791556175`.
Its containers were stopped and synthetic volumes retained; no data reset was used.
Earlier successful isolated acceptance runs were also stopped with volumes retained.
An earlier browser handle could not export screenshots. A fresh tab verified the
merged dashboard and saved [synthetic screenshot evidence](../qa/qwen-web-verification.jpg).
A fresh checkout also retrieved the actual LFS object and completed `qwen-setup.sh`,
verifying the same SHA-256 before local import. Main advanced with dashboard/watch UI
changes during implementation; those were integrated and affected regressions rerun.

## Observed performance

These are synthetic single-run observations under concurrent host work, not calibrated
device benchmarks. RSS is the process high-water mark, including runtime/context/UI.

| Runtime | Tokens | Initialization | Completion/request | Tokens/s | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Local Ollama echo, latest aggregate run | 9 | warm cached runner | 0.821 s request | 90.2 | not measured |
| iPhone 17 Pro simulator, latest app run | 8 | 0.658 s | 1.785 s | 9.67 | 1,078,607,872 bytes |
| Watch Series 11 (46mm) simulator, latest app run | 8 | 1.498 s | 2.096 s | 39.90 | 723,025,920 bytes |
| Native macOS, external network denied | 9 | measured separately by engine | 0.876 s | 39.12 | 730,234,880 bytes |

Earlier simulator samples in the integration guide differ because host load and
memory pressure differ. No claim of comparable simulator/physical-device speed,
battery efficiency, thermal stability or medical extraction accuracy is made.

## Changed files and remaining requirements

Changes reach `models/qwen3-0.6b`, `.gitattributes`, `vendor/llama.cpp`,
`watch/apple` app/project/native source/resources/tests, `hub/model.js`,
`hub/ai.js`, `hub/server.js`, dashboard and AI/model tests, Docker Compose,
isolated QA Compose, setup/build/verification scripts, environment examples,
CI fixture/packaging checks, README, architecture/API/AI contracts and migration
ownership documentation. Existing Flutter/hub applied migrations were not rewritten.

Physical iPhone/Watch installation requires a signing team and devices. Validate
memory/jetsam, responsiveness, cancellations during loading, supported on-device
speech locale assets, audio recovery, app relaunch, background restrictions,
Watch disconnection/reconnection, duplicate/interrupted file transfers and durable
fallback return. A ~378 MiB model plus runtime/context can exceed a Watch process
budget; simulator success cannot resolve that risk. Original captures remain durable
when loading fails, and optional iPhone fallback remains necessary.

Qwen output can misread negation or contradiction despite matching an excerpt.
Schema/excerpt validation does not establish clinical truth. Machine claims stay
unverified and do not independently determine hospital urgency. Qualified verification
and clinical evaluation are still required. Offline Watch STT and browser-native
inference were not implemented. Existing unauthenticated HTTP and unencrypted SQLite
remain prototype limits; this is not a real-patient deployment.

The feature branch/PR is for manual review and merging after its required CI checks
and teammate review. No deployment, merge or repository protection change is authorized
by this implementation report. Live GitHub CI status is recorded in the PR description,
not inferred from the local results above.
