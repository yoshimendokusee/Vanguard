# Triage delivery update

This update keeps the existing offline-first monolith and makes the report path explicit. A completed local capture is saved before any network attempt. The Watch sends directly to the configured LAN hub when available; a paired iPhone can relay the same immutable packet when direct Watch delivery is unavailable. The hub validates and persists the packet in SQLite, and the sender remains pending until an acknowledgment is received. Retries use the existing report identity and preserve the original intake, transcript, provenance, and correction history.

## Transcript output contract

The public extraction contains exactly these five observations:

1. Breathing
2. Consciousness
3. Severe bleeding
4. Walking ability
5. Circulation

Each value is explicit, including `unknown`. The screenshot’s example values are not defaults and are never fabricated. RAG findings remain in the processing payload and dashboard as quote-grounded supporting evidence. Qwen3-0.6B still produces the existing four required observations; circulation is added by deterministic transcript confirmation, so the model cannot assign or override triage urgency. Triage remains provisional.

## Delivery and dashboard behavior

The Watch workflow no longer asks for Pickup Location. It automatically opens the triage result, shows the five observations and RAG findings, saves locally, and reports Sending, Pending Sync, Failed, or acknowledged delivery states. The iPhone fallback uses the same report schema and preserves the Watch encounter identity when relaying.

The hub adds scoped device source lookup and correction endpoints while preserving the existing ingestion and correction contracts. Device corrections are checked against immutable source history and optimistic revisions, so a retry cannot overwrite a newer hospital correction. No database migration or reset was introduced. The dashboard now renders the real report queue, original transcript, five observations, RAG evidence, delivery clocks, corrections, and provisional machine advisory. SSE and polling continue to recover from temporary connection loss; empty queues use the required no-report message.

## Static checks performed

- `flutter analyze --no-pub` — passed.
- `dart format lib/services/ai_service.dart` — passed with no changes.
- `xcrun swift build --package-path watch/apple --target VanguardApple` — passed.
- Unsigned generic watchOS Xcode build — passed (`** BUILD SUCCEEDED **`).
- Unsigned generic iOS Xcode build — passed (`** BUILD SUCCEEDED **`).
- `npm run build` in `hub` — passed.
- JavaScript syntax checks, JSON parsing, and `git diff --check` — passed.

The Xcode builds retain the existing AppIntents metadata warning because Vanguard has no AppIntents framework dependency. SwiftLint is not installed in this environment. No functional tests, simulators, hardware, API smoke tests, or automated report transmission checks were run, per request.

## Manual checklist

- Record a Watch report and confirm the five observation labels plus RAG findings are the only extraction output.
- Confirm the original transcript remains visible and unchanged after a correction.
- With LAN available, verify local save, Sending, hub persistence, acknowledgment, and dashboard appearance.
- Disable connectivity, restart the Watch/iPhone, then restore LAN and verify queued retry and duplicate prevention.
- Exercise iPhone relay and direct Watch delivery independently.
- Submit an older correction after a newer hospital edit and verify it remains queued for reconciliation.
- Open a legacy four-observation row and verify circulation displays `Unknown` without changing historical triage.

## Files changed

Contracts and workflow documentation:

- `docs/ai-contract.md`
- `docs/api-contract.md`
- `docs/apple-watch-voice-workflow.md`
- `docs/architecture.md`
- `docs/fixtures/native-processing-v1.json`
- `docs/triage-delivery-update.md`

Hub implementation, dashboard, and coverage:

- `hub/access.js`, `hub/access.test.js`
- `hub/ai.js`, `hub/ai.test.js`
- `hub/clinical.js`
- `hub/contract.test.js`
- `hub/intake.js`, `hub/native-contract.test.js`
- `hub/processing.js`
- `hub/public/dashboard.css`, `hub/public/dashboard.js`, `hub/public/hub-client.js`, `hub/public/index.html`
- `hub/rag/integration.test.js`
- `hub/risk.js`, `hub/risk.test.js`
- `hub/server.js`

Native Watch/iPhone workflow and coverage:

- `watch/apple/App/VanguardApp.swift`
- `watch/apple/Sources/VanguardApple/AiContract.swift`
- `watch/apple/Sources/VanguardApple/NativeClinical.swift`
- `watch/apple/Sources/VanguardApple/NativeStore+Voice.swift`
- `watch/apple/Sources/VanguardApple/NativeWorkflow.swift`
- `watch/apple/Sources/VanguardApple/ObservationConfirmation.swift`
- `watch/apple/Sources/VanguardApple/Triage.swift`
- `watch/apple/Sources/VanguardApple/VoiceReportController.swift`
- `watch/apple/Sources/VanguardApple/VoiceRuntime.swift`
- `watch/apple/Sources/VanguardApple/WatchRelay.swift`
- `watch/apple/Sources/VanguardApple/WatchUI/WatchRootView.swift`
- `watch/apple/Sources/VanguardApple/WatchUI/WatchScreens.swift`
- `watch/apple/Tests/VanguardAppleTests/DeliveryTests.swift`
- `watch/apple/Tests/VanguardAppleTests/HubContractTests.swift`
- `watch/apple/Tests/VanguardAppleTests/ObservationParityTests.swift`
- `watch/apple/Tests/VanguardAppleTests/VoiceReportControllerTests.swift`
- `watch/lib/services/ai_service.dart`

No commit or remote operation was performed.
