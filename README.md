# Pocket Apple app

Pocket is the account-free companion for Xteink X3 and X4 Crosspoint readers. Bluetooth
performs secure discovery and hands the app a temporary private Wi-Fi lease;
the existing CrossPoint WebSocket endpoint carries books, learning packs, and
firmware to the SD card.

This first vertical slice includes:

- iPhone/iPad and macOS SwiftUI targets under one App Store bundle identifier
- CoreBluetooth discovery, system passkey pairing, and encrypted control records
- automatic private-hotspot joining on iOS and a visible manual fallback on macOS
- `/api/status` identity verification before transfer
- streamed WebSocket uploads without loading the whole file into memory
- direct, atomic copies to a user-selected mounted SD-card folder on macOS
- deterministic parsing tests for status and hotspot lease records

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

For an App Store archive, select the project development team and enable the
Hotspot Configuration capability for the iOS app identifier. The macOS target
uses App Sandbox with Bluetooth, outgoing network, user-selected file, and
security-scoped bookmark permissions. Selecting the mounted SD-card directory
grants recursive access to that directory.

## Current transfer routing

- `.pdl` learning packs are written to `/pocket-daily/learning`.
- EPUBs and selected firmware `.bin` files are written to the SD-card root.
- `.cpfont` files copied directly to SD are magic-checked and routed to their
  derived `/.fonts/<family>` directory. Wireless font installation still uses
  the reader's validated Fonts endpoint and is not exposed by this first slice.

The on-device firmware picker validates a `.bin` again before flashing it.
Transport completion alone never installs firmware automatically.
