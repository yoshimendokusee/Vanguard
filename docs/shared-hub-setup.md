# Shared Docker hub — verification on 2026-10-10

The configured Apple build-time URL is **`http://Barons-MacBook-Pro.local:3000`**.
Only this Mac runs the hub; clients on the same isolated test LAN share its existing
hospital database. The user selected this hostname after the Mac moved from
`192.168.0.103` to `192.168.68.55`. The earlier numeric-IP verification remains in
[Apple hub URL verification](apple-hub-url-verification.md).

## Local configuration

Git-ignored root `.env` has permissions `0600` and contains:

```dotenv
HUB_BIND_ADDRESS=192.168.68.55
HUB_PORT=3000
```

Its `HUB_USERS` contains one operator and two device principals, each with a
different random 64-character token. The device principals are restricted to the
IDs displayed by the verification iPhone and Watch simulators. Tokens were never
printed or committed. Physical clients are not enrolled: give each installation
its own random token and exact displayed device ID in `HUB_USERS`, recreate only
the hub, then privately enter that device's token in its Hospital access token field.
Keep the operator token for the web board; do not give it to clients.
Existing hub Supabase configuration was preserved (all cloud values were empty).

Git-ignored `watch/apple/Config/Secrets.xcconfig` contains:

```xcconfig
HUB_URL = http:/$()/Barons-MacBook-Pro.local:3000
SUPABASE_URL =
SUPABASE_PUBLISHABLE_KEY =
```

The hostname uses macOS Bonjour/mDNS. Clients need to share the LAN and the router
must permit client communication and mDNS. No router port forwarding is needed.
Physical-device hostname resolution has not been checked. The direct current-IP
fallback is `http://192.168.68.55:3000`.

Docker binds specifically to the Wi-Fi IP, rather than every interface. A hostname
does not update Docker's binding: if DHCP changes the IP, update `HUB_BIND_ADDRESS`
in `.env` and run `docker compose up -d --no-deps --force-recreate hub` again. A
router DHCP reservation avoids that maintenance; no reservation was configured.
The original `192.168.0.103` startup failed with `can't assign requested address`
after the network changed. Localhost service was restored before switching to the
new user-confirmed isolated LAN.

## Commands and results

Commands ran at repository root unless indicated otherwise. Build logs/products
are in `/tmp/vanguard-shared-hub.qOlBEd`; no API, schema, dependency, target or
tracked signing setting changed.

| Command/check | Result |
| --- | --- |
| `git check-ignore -v .env watch/apple/Config/Secrets.xcconfig` | Both ignored; `.env` mode `0600`. |
| `docker compose config --quiet` | Passed. |
| `docker compose --env-file .env -f hub/docker-compose.yml config --quiet` | Passed. |
| `docker compose build hub` | Passed. |
| `docker run --rm -e DB_PATH=:memory: -e LIVE_AI=0 -v "$PWD/docs:/docs:ro" -v "$PWD/watch/lib:/watch/lib:ro" -v "$PWD/models:/models:ro" vanguard-hub node --test` | Node 22 image: 69 tests, 68 passed, 1 skipped (`LIVE_AI=0`), 0 failures. Includes authentication, assigned-device isolation and sync tests. No existing database mounted. |
| `docker compose up -d --no-deps --force-recreate hub` | Passed with `192.168.68.55:3000` after the failed old-IP attempt. |
| Filtered `docker inspect` comparison | Hub `/data` bind and model volume unchanged. Frontend and Ollama container IDs and mounts unchanged. Only hub recreated. No reset or volume deletion. |
| Host HTTP `/api/health` checks | HTTP 200 via both current IP and `Barons-MacBook-Pro.local`. |
| Independent Docker client fetch of `http://192.168.68.55:3000/api/health` | HTTP 200; a virtual client check, not a physical LAN-device check. |
| Credentialed `/api/config` read for all three principals | HTTP 200 for operator, verification iPhone and verification Watch. No report writes to the shared database. |
| Isolated in-memory QA hub using actual device scopes | Two synthetic identities accepted and acknowledged. Wrong token: 401; crossed identity: 403; device hospital-record read: 403; anonymous config read: 401. Operator saw exactly two synthetic reports. |
| Signed simulator `xcodebuild` commands below | iPhone and Watch passed with ad-hoc signing. |
| `codesign --verify` and `plistlib` assertions | iPhone, standalone Watch and embedded Watch passed. Exact hostname URL, both Supabase values empty, microphone/speech/local-network descriptions and `NSAppTransportSecurity.NSAllowsLocalNetworking = true`. |
| `git diff --check` | Passed. |

Both builds used `watch/apple` as their working directory:

```sh
xcodebuild -project Vanguard.xcodeproj -scheme VanguardPhone \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/vanguard-shared-hub.qOlBEd/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
xcodebuild -project Vanguard.xcodeproj -scheme VanguardWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/vanguard-shared-hub.qOlBEd/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

Final plists in `DerivedData/Build/Products` all contain
`HUB_URL = http://Barons-MacBook-Pro.local:3000`:

- `Debug-iphonesimulator/VanguardPhone.app/Info.plist`
- `Debug-watchsimulator/VanguardWatch.app/Info.plist`
- `Debug-iphonesimulator/VanguardPhone.app/Watch/VanguardWatch.app/Info.plist`

## Signed client verification

The existing separate verification iPhone simulator received its assigned token
through the secure app field. Ad-hoc signing resolved the earlier unsigned
`missingCredential` failure without changing app code or project signing settings.
A typed URL override and the masked Keychain credential survived terminate/launch.
The original fresh-install numeric-IP prefill passed in the earlier report. A
separate clean simulator (`Vanguard Hostname Prefill Verification`) booted and
had no Vanguard data before install, but its installer stalled and ended with
NSMachErrorDomain `-308` when the test simulator was stopped. That additional
hostname prefill check remains unverified; no existing app data was cleared.

Synthetic relay tests used a temporary hub on port 3002 with `DB_PATH=:memory:`;
the shared hospital database and model/data volumes were not mounted there.
The iPhone captured and locally extracted two synthetic inputs. The first received
an acknowledgment. With the QA hub paused, the second stayed pending after timeout
and app relaunch: two originals, two extractions, one receipt, one pending report.
After unpausing and pressing Retry hospital relay, the second was acknowledged:
two originals, two extractions, two receipts, zero pending. Counts only were checked;
no transcripts or credentials were printed. Both originals remain in the test
client's SQLite database. The iPhone was returned to the shared hostname on port
3000 with an empty outbox; it connected and retained URL/token after relaunch.

The QA hub and temporary private credential-entry helper were removed/stopped.
The Watch signed build installed and launched, but Device Hub exposed no Watch app
controls to automation, and coordinate input failed with `noWindowsAvailable`.
Its assigned token was not entered; Watch Keychain persistence, hostname resolution,
synthetic acknowledgment and disconnected retention remain unverified. The Watch
and unsuccessful clean-install test simulators are stopped; the verified iPhone
test client remains available with both synthetic originals preserved.

## Files and limits

This shared-hub work changes only ignored `.env`, ignored `Secrets.xcconfig`, this
report and documentation links in `README.md`/`architecture.md`. Earlier changes to
`Config/Info.plist` and `project.pbxproj` preserve the nested ATS key; no further
project-file change was needed. Nothing was committed or pushed.

Physical iPhone/Watch connectivity and enrollment, paired Watch transfer, router
DHCP reservation, physical-device/distribution signing, Release builds and hosted
CI are unverified. Automatic discovery and multiple Docker hosts were skipped.
HTTP and local SQLite remain unencrypted; use only synthetic data on the isolated
test LAN. Device credentials do not establish trusted clinical delivery.
