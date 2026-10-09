# Apple build-time hub URL verification — 2026-10-10

Verified on macOS with Xcode 27.0 (27A266a), Swift 6.4 and simulator SDKs 27.0.
The generated URL is `http://192.168.0.103:3000`, using this Mac's active Wi-Fi
address (`en0`). This assumes this Mac is the hub laptop; a different hub laptop
requires its own address and a rebuild. DHCP can change the address.

## Configuration and changes

- Initial `git status --short` was clean; every file requested for inspection existed.
- Copied `Config/Secrets.xcconfig.example` to the ignored `Config/Secrets.xcconfig`.
  Set `HUB_URL = http:/$()/192.168.0.103:3000`; both app Supabase values are empty.
  No server credentials were added to an app or changed in the hub.
- `git check-ignore -v watch/apple/Config/Secrets.xcconfig` passed using
  `.gitignore:14:Secrets.xcconfig`.
- Both project-level configurations reference `Config/Vanguard.xcconfig`.
  Both targets inherit the expected URL in Debug and Release and use
  `INFOPLIST_FILE = Config/Info.plist`, `GENERATE_INFOPLIST_FILE = YES`.
- Initial simulator builds succeeded, but their plists lacked the ATS dictionary.
  Added `NSAppTransportSecurity.NSAllowsLocalNetworking = true` to the shared
  `Config/Info.plist`; removed four ineffective
  `INFOPLIST_KEY_NSAppTransportSecurity_NSAllowsLocalNetworking` settings from
  `project.pbxproj`. Permission descriptions remain target build settings.
  Xcode loaded the project without rejecting or rewriting it.
- `AppConfiguration.swift`, its tests, app code, dependencies, targets and signing
  settings required no changes. Updated `architecture.md` and `README.md` to link
  this evidence and distinguish a saved override from an unsaved edit.

## Commands and results

Commands below ran from `watch/apple` unless indicated otherwise.
Build logs/products used `/tmp/vanguard-hub-url.TyqTQY`, outside the repository.

| Command/check | Result |
| --- | --- |
| `xcrun swift test` | 19 tests: 18 passed, 1 skipped, 0 failures. All 4 AppConfiguration tests passed. Live inference skipped because `VANGUARD_LIVE_MODEL_DIR` was unset; corrupt-model fixture diagnostics were expected. |
| `xcodebuild -list -project Vanguard.xcodeproj` | Passed before and after the fix; both app targets/schemes and Debug/Release loaded. |
| `xcodebuild -project Vanguard.xcodeproj -alltargets -configuration Debug -showBuildSettings -json` (also Release) | Both configurations passed assertions for the inherited URL, empty cloud values and plist settings; project base references checked via `plutil` conversion. |
| `xcodebuild -project Vanguard.xcodeproj -scheme VanguardPhone -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/vanguard-hub-url.TyqTQY/DerivedData CODE_SIGNING_ALLOWED=NO build` | Passed initially and after the ATS fix (2 builds). |
| Same build with `-scheme VanguardWatch -destination 'generic/platform=watchOS Simulator'` | Passed initially and after the ATS fix (2 builds). |
| `plutil -lint` on source plist and project | Both passed. |
| `plutil -p <app>/Info.plist`, followed by Python `plistlib` assertions | All 3 final app plists passed: iPhone, standalone Watch, embedded Watch. |
| `git diff --check` | Passed. |
| `ipconfig getifaddr en0`, `route -n get default` | Active LAN address `192.168.0.103`. |
| `lsof -nP -iTCP:3000 -sTCP:LISTEN` (repository root) | Docker listener bound only to `127.0.0.1:3000`. |
| `curl --connect-timeout 2 --max-time 3 http://192.168.0.103:3000/health` (status only) | Failed to connect: exit 7, HTTP 000. No records accessed. |

Final products are under `DerivedData/Build/Products`:

| App plist | HUB_URL | Supabase values | Permissions / ATS |
| --- | --- | --- | --- |
| `Debug-iphonesimulator/VanguardPhone.app/Info.plist` | `http://192.168.0.103:3000` | Both empty | All present |
| `Debug-watchsimulator/VanguardWatch.app/Info.plist` | `http://192.168.0.103:3000` | Both empty | All present |
| `Debug-iphonesimulator/VanguardPhone.app/Watch/VanguardWatch.app/Info.plist` | `http://192.168.0.103:3000` | Both empty | All present |

Assertions checked exact URL equality with no unresolved `$(`, empty
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`, nonempty microphone/speech/local
network usage descriptions, and boolean `NSAllowsLocalNetworking = true`.

## Simulator and remaining verification

A fresh iPhone 17 simulator initially stalled in `CoreLocationMigrator`; its
display timed out and the first install attempt ended with NSMachErrorDomain
`-308`. A restart did not resolve first-boot migration. An initialized iPad clone
booted but its install/launch attempt also failed with `-308`; it was stopped.
Neither attempt counts as an app verification pass.

The successful UI check used a separate clone of the shutdown iPhone 17 simulator:

```sh
xcrun simctl clone F0CD7D9F-2D80-496C-A3A2-EBE652B25FE5 'Vanguard iPhone Hub URL Verification'
xcrun simctl boot C1AFB4B5-C42B-4716-82D3-B2768F19B9EE
xcrun simctl bootstatus C1AFB4B5-C42B-4716-82D3-B2768F19B9EE -b
xcrun simctl get_app_container C1AFB4B5-C42B-4716-82D3-B2768F19B9EE ph.vanguard.ios data
xcrun simctl install C1AFB4B5-C42B-4716-82D3-B2768F19B9EE /tmp/vanguard-hub-url.TyqTQY/DerivedData/Build/Products/Debug-iphonesimulator/VanguardPhone.app
xcrun simctl launch C1AFB4B5-C42B-4716-82D3-B2768F19B9EE ph.vanguard.ios
```

Clone, boot, install and launch passed. Before installation, `get_app_container`
returned exit 2 (no Vanguard app data), establishing a clean app installation
without clearing an existing report store. Existing simulators were preserved.
The UI ran on iOS 26.5 and was inspected/edited through Device Hub accessibility.

- **Prefill passed:** Hospital LAN URL displayed `http://192.168.0.103:3000`.
- **Typed override failed:** entered `http://192.168.0.103:3001`, terminated and
  relaunched with `xcrun simctl terminate/launch`; the field reverted to the
  build-time `:3000` value.
- Repeated after entering the URL and pressing **Retry hospital relay** with no
  reports captured. The UI reported `missingCredential`; relaunch again reverted
  to `:3000`. In current `CaptureModel.sync()`, `HubCredential.save()` precedes
  writing `UserDefaults["vanguard-hub"]`, so a Keychain failure prevents the save.
  Typing alone has no immediate persistence hook. App behavior and signing were
  preserved; successful persisted-override precedence remains unverified.

No reports were created or transmitted; no hospital receipt was verified.
The two unsuccessful test simulators are stopped; the successful iPhone clone is
left running for inspection.
Physical devices, paired Watch transfer, signing, Release app builds and hosted CI
are unverified. Hub/Flutter suites were not run because their code was unchanged.
The LAN endpoint is unavailable at the generated address; no network exposure or
hub configuration was changed. HTTP and local storage remain prototype limitations.
