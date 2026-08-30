# Pocket Apple app

Pocket is the account-free companion for Xteink X3 and X4 Crosspoint readers. Bluetooth
performs secure discovery and hands the app a temporary private Wi-Fi lease;
verified HTTP staging carries books, learning packs, and firmware to the SD
card without requiring the home Wi-Fi network.

This first vertical slice includes:

- iPhone/iPad and macOS SwiftUI targets under one App Store bundle identifier
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

It does not require Pocket Hub, a user account, AgentDeck, or infrastructure
Wi-Fi. AgentDeck remains an optional device mode outside this app.

## Build

The checked-in Xcode project is generated from `project.yml` with XcodeGen:

```sh
cd apps/Pocket
xcodegen generate
xcodebuild -project Pocket.xcodeproj -scheme Pocket -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Pocket.xcodeproj -scheme PocketMac -sdk macosx CODE_SIGNING_ALLOWED=NO build
```

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
Transport completion alone never installs firmware automatically.
