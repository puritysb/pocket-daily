# Pocket Daily

Pocket Daily is the account-free companion for X3/X4 hardware running Pocket
Daily or compatible CrossPoint-based firmware. It does not connect to the
manufacturer's factory firmware or cloud service. Find on same Wi-Fi searches the current network without changing Wi-Fi. Connect
directly uses Bluetooth pairing and a temporary reader Wi-Fi network when away,
without requiring a router or internet. Prepare files locally before connecting,
then send the prepared batch with verified HTTP staging.

This first vertical slice includes:

- iPhone/iPad and macOS SwiftUI targets under one App Store bundle identifier
- one studio on every platform: a Home & Sleep editor for the reader's Pocket
  Daily profile, reader settings and "My cards" (with QR codes), previewed
  with the firmware's own layout code and sent with a single explicit Send
- books (EPUB, TXT, Markdown, XTC) and typed or pasted text sent to the reader
- weather for a chosen city (Apple WeatherKit) and, optionally, today's calendar
  events, sent to the reader on connection and with each Send
- CoreBluetooth discovery, system passkey pairing, and encrypted control records
- automatic private-hotspot joining on iOS and macOS, with a visible manual
  fallback when association is unavailable
- `/api/status` identity verification before transfer
- streamed multipart uploads with byte progress, CRC32 verification, and
  atomic publication from a hidden staging file
- direct, atomic copies to a user-selected mounted SD-card folder on macOS
- deterministic parsing tests for status and hotspot lease records
- automatic retrieval, classification, display, and export of the reader's
  retained crash report, plus a persistent local Bluetooth connection trace
- a local-only demo mode for App Review and first-run exploration; transfer and
  device mutation stay disabled until a real reader is connected
- an original Pocket Daily icon set, App Store metadata, required-size actual UI
  screenshots, public privacy/support pages, and submission validation tooling

It does not require Pocket Hub, a user account, or infrastructure Wi-Fi. The
reader's weather (Apple Weather for a chosen city) and today's events (from the
device's calendars, optional) come from this app; the former AgentDeck daemon
path was removed from the firmware.

Pocket Daily is an independent project. It is not affiliated with or endorsed by
CrossPoint Reader, Xteink, or any device manufacturer. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for compatibility and licensing
acknowledgements and [`PRIVACY.md`](PRIVACY.md) for the local-only data policy.

The app uses a neutral Pocket Daily device-profile illustration rather than
manufacturer logos, product photography, or official application assets.

## Build

The checked-in Xcode project is generated from `project.yml` with XcodeGen:

```sh
xcodegen generate
xcodebuild -project Pocket.xcodeproj -scheme Pocket -sdk iphonesimulator -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Pocket.xcodeproj -scheme PocketMac -sdk macosx -derivedDataPath .build/mac CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Pocket.xcodeproj -scheme Pocket -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -derivedDataPath .build/tests CODE_SIGNING_ALLOWED=NO
```

Use an available simulator name and OS when the example runtime is not
installed. Treat `project.yml` as the source of truth: regenerate with XcodeGen
after project or file-membership changes, and do not hand-edit
`Pocket.xcodeproj/project.pbxproj`.

Agent-assisted work starts with [`AGENTS.md`](AGENTS.md), the single instruction
file for every coding agent, covering product constraints and workflow. Dated
durable handoff context is in [`docs/PROJECT_MEMORY.md`](docs/PROJECT_MEMORY.md).

For local macOS hardware testing, sign the built app with a Developer ID
identity and `Support/PocketMacDeveloperID.entitlements`. This keeps Bluetooth,
location-gated Wi-Fi discovery, and outgoing network access while deliberately
leaving App Sandbox out of the local test signature. The App Store target
continues to use `Support/PocketMac.entitlements` and remains sandboxed.

```sh
POCKET_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
codesign --force --deep --options runtime --timestamp=none \
  --sign "$POCKET_SIGN_IDENTITY" \
  --entitlements Support/PocketMacDeveloperID.entitlements \
  /path/to/DerivedData/Build/Products/Debug/Pocket.app
```

For an App Store archive, select the project development team and enable the
Hotspot Configuration capability for the iOS app identifier. The macOS target
uses App Sandbox with Bluetooth, outgoing network, user-selected file,
security-scoped bookmark, and location permissions. macOS uses location only
because CoreWLAN gates nearby SSID scanning behind it; Pocket never requests
coordinates. Selecting the mounted SD-card directory grants recursive access
to that directory.

## Current transfer routing

- `.pdl` learning packs are written to `/pocket-daily/learning`.
- EPUBs are written to the SD-card root. Selected firmware `.bin` files are
  verified and published as `/update.bin` for the on-device updater.
- `.cpfont` files copied directly to SD are magic-checked and routed to their
  derived `/.fonts/<family>` directory. Wireless font installation still uses
  the reader's validated Fonts endpoint and is not exposed by this first slice.

The on-device firmware picker validates a `.bin` again before flashing it.
Transport completion alone never installs firmware automatically. Before a
firmware transfer, the app explains the compatibility, recovery, and possible
support/warranty implications and requires an explicit acknowledgement.

## App Store submission

The review setup, hardware dependency, compatibility wording, and firmware
safety boundary are documented in [`APP_STORE_REVIEW.md`](APP_STORE_REVIEW.md).
The complete staged submission package is under [`appstore/`](appstore/). After
any user-facing UI change run `scripts/capture_screenshots.sh` to regenerate the
screenshots from the real demo interface, and run `scripts/validate_app_store.sh`
before every App Store Connect upload.

## Prepare, connect, and send

1. Choose a book, study pack, or firmware while internet is available. The app
   copies it into its local prepared list; firmware requires acknowledgement and
   image validation. Add files one at a time; only one firmware image may be pending.
2. At home, open File Transfer → Join a Network on the reader and choose Find
   on same Wi-Fi under Reader in the app. New firmware also offers Join a Network
   in the Pocket Sync menu and reuses saved reader Wi-Fi credentials.
3. Away, open Nearby Sync on the reader (select Nearby Sync again in the new
   transport chooser), then choose Connect directly in the app and approve the
   temporary Wi-Fi switch. No internet is required for prepared files.
4. Choose Send under Ready to send. Keep the iPhone app in the foreground. A paused or failed
   file remains local across app relaunch; reconnect and send again. Identified
   readers reuse the staging ID. Resume requires the reader to retain its session;
   a reader restart safely restarts the file at zero.
5. A completed direct batch releases the app's temporary Wi-Fi configuration.
   New private-AP firmware also accepts session/end and returns to Pocket Daily.
   Older firmware requires exiting Sync on the reader or waiting for idle expiry.
   The OS controls reconnection to your usual network.
6. Firmware is staged as /update.bin, never installed automatically. Confirm on
   the reader, then reconnect to check the version. Checks are scoped to the
   reader ID; unidentified legacy LAN/SD staging cannot be confirmed automatically.

Direct sessions defer optional preview/crash downloads to preserve X3 heap.
Device IDs distinguish readers but do not cryptographically authenticate LAN HTTP.
