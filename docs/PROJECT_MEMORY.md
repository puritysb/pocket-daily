# Pocket Daily Project Memory

This is curated, repository-owned context for future work sessions. It is not a
chat transcript. Prefer current code and release manifests when they conflict
with a dated note below.

## Repository split

- App Store app: `/Users/puritysb/github/pocket-daily`
  (`https://github.com/puritysb/pocket-daily`)
- Reader firmware: `/Users/puritysb/github/pocket-daily-firmware`
  (`https://github.com/puritysb/pocket-daily-firmware`)

The app repository owns iOS, iPadOS, and macOS code, XcodeGen configuration,
App Store metadata, screenshots, privacy/support pages, and the client side of
device protocols. The firmware repository owns device behavior, endpoints,
on-device validation, and flashing. Coordinate any protocol or file-layout
change across both repositories.

The previous combined project's Claude memories were firmware- and
AgentDeck-heavy. They were intentionally not copied here. Promote only a
verified, app-relevant durable fact into this file.

## Verified baseline — 2026-09-01

- The default branch was `main` and matched `origin/main` at the time of the
  setup audit.
- XcodeGen 2.45.3 generated the checked-in project successfully.
- The `PocketMac` macOS build succeeded without code signing.
- The `Pocket` iOS simulator suite passed 17 of 17 tests on an iPhone 16 Pro
  simulator running iOS 18.6.
- `scripts/validate_app_store.sh` passed the staged metadata, screenshots,
  icons, and export-compliance checks.
- The release manifest described version 1.0.0, build 1, and bundle identifier
  `io.github.puritysb.pocketdaily`.

These are historical verification facts, not permanent configuration. Read
`project.yml` and `appstore/submission.json` for the current values and rerun
the relevant checks before release work.

## Durable implementation notes

- `project.yml` is the Xcode project source of truth. Regenerate with XcodeGen;
  do not hand-edit `Pocket.xcodeproj/project.pbxproj`.
- iOS and macOS share `Sources/`. Keep platform differences focused and preserve
  a single universal-product experience.
- Real Bluetooth, hotspot, local-network, mounted-volume, and TestFlight flows
  require physical hardware. Demo mode is local and non-mutating.
- A wireless firmware transfer only stages a validated file as `/update.bin`.
  The reader validates it again and requires confirmation before flashing.
- App-side firmware validation checks the ESP32-C3 image structure, segment
  bounds, checksum, appended digest when present, and stable CrossPoint/Pocket
  Nearby Sync product markers before either wireless or SD publication.
- `Sources/PrivacyInfo.xcprivacy` is bundled in both products. Its required-reason
  entries cover app-only UserDefaults and metadata of user-selected files.
- The App Store macOS target stays sandboxed. Local Developer ID hardware tests
  use `Support/PocketMacDeveloperID.entitlements` deliberately and separately.
- Pocket Daily is account-free, has no analytics or cloud backend, and uses
  local connectivity only.

## App Store hand-off boundary

The repository contains the staged submission package and its validator.
App Store Connect account state is external. Agreements, banking/tax state,
certificates, identifiers, app-record creation, build upload, TestFlight review,
submission, and manual release require account-holder access and must be
verified in App Store Connect.

## Release preparation — 2026-09-01

- Organization team `QF36NDHYHD` registered the explicit App ID
  `bound.serendipity.pocket.daily` and created matching iOS and Mac App Store
  profiles. The iOS profile retains Hotspot Configuration; the macOS product
  retains App Sandbox and its required device, network, file, and location
  entitlements.
- Signed iOS and macOS archives exported successfully as an App Store IPA and
  PKG. Both exported products use Apple Distribution signing, include the shared
  privacy manifest, and have distribution profiles that expire in August 2027.
- On this host, run `xcodebuild -exportArchive` with a system-only `PATH`
  (`/usr/bin:/bin:/usr/sbin:/sbin`). A Homebrew rsync child otherwise conflicts
  with Xcode's Apple rsync flags and fails the IPA copy step.
- The iOS simulator suite passed 26 of 26 tests after adding firmware-image
  validation, and both affected platform release builds passed.
- `scripts/package_app_store.sh` passed end to end: it regenerates the project,
  validates submission assets, runs the iOS suite, archives and locally exports
  both Store products, and calls `scripts/verify_app_store_distributions.sh` to
  emit signed-artifact hashes and package evidence. It never uploads.
- After refreshing the Xcode Apple account, the full local package pipeline
  passed for `bound.serendipity.pocket.daily`: 26 of 26 iOS simulator tests,
  signed iOS IPA export, signed universal macOS PKG export, profile and
  entitlement checks, and privacy-manifest verification. No build was uploaded
  or validated by App Store Connect, so local Store export success is not yet
  evidence of server acceptance.
- The marketing, support, and privacy URLs configured for App Store Connect each
  returned HTTP 200 from the public GitHub Pages site.
- App Review still requires a physical X3/X4 transfer video and real-reader
  TestFlight verification on iOS/iPadOS and macOS.

## Exact reader-frame preview contract — 2026-09-02

- Pocket Daily no longer maintains separate SwiftUI sample surfaces that can
  drift from the reader. Firmware captures the actual 1-bit framebuffer as a
  transient BMP immediately before Pocket Daily enters Nearby Sync.
- During the authenticated Nearby Sync profile, `/api/status` advertises
  `screenPreviewAvailable` and `screenPreviewBytes`; the app retrieves the BMP
  from `/api/pocket/v1/screen-preview` and renders it without interpolation.
- This is the exact frame captured before Sync opened, not a continuously
  streamed display. File Transfer and hardware-free demo mode intentionally
  show an explicit profile/unavailable state instead of fabricated content.
- The contract compiled on iOS and macOS and the iOS suite passed 27 of 27
  tests. Physical X3 transfer, decode, and visual sign-off remain required.

## Resumable upload stream contract — 2026-09-02

- `PocketStreamUploader` reads reader replies concurrently with sending, so an
  early `ERROR …` line surfaces its message instead of a generic disconnect,
  and a 30-second stall watchdog (matching the reader's idle timeout) turns a
  dropped hotspot into a retryable failure instead of a 15-minute wait.
- `uploadAtomically` keeps one staging name across up to three attempts.
  Link-level failures retry after a short delay; when the reader is
  unreachable the model rejoins the leased hotspot first. Readers that
  advertise `uploadStreamResume` receive `Resume: 1` and answer
  `RESUME <received>`; the app then rebuilds its CRC over that prefix and
  sends only the remainder. Reader rejections and checksum mismatches are
  never retried.
- `UploadRetryPolicy` and the reply/header grammar are pure and unit-tested;
  two loopback tests drive the uploader against a scripted fake reader.
  Physical X3/X4 transfer, hotspot drop, and resume remain hardware sign-off.

## Hardware findings — 2026-09-03

- On an X3 running the 2026-09-02 01:30 firmware, the private Nearby Sync AP
  left only 6.4-7.0 KB free heap, and the app's post-connect screen-preview and
  crash-report fetches hung the reader (task watchdog, breadcrumb
  `nearby:screen-preview`) twice. The app now skips both fetches when
  `diagnosticsAffordable` is false or free heap is below 10 KB
  (`ReaderDiagnosticsPolicy`) and says so in the status message.
- The same file over STA File Transfer moved at ~105 KB/s (6 MB in 57.5 s) on
  the old 768-byte firmware path; that is the baseline for the batched build.
- Hardware iteration goes through File Transfer → Join a Network plus the
  firmware repo's `scripts/pocket_put.py`, not SD-card swapping.

## Transfer path decision — 2026-09-05

- Use File Transfer → Join a Network (reader on the home Wi-Fi) as the primary
  path for firmware and content transfers; the app's LAN discovery finds the
  reader and uses the same verified stream with batching, resume, and retry.
  It completed every transfer in testing. The private Sync hotspot is the
  weakest path on the X3 and remains a fallback for readers without shared
  Wi-Fi.
- The app heartbeat now tolerates five consecutive misses with a 6 s timeout so
  a weak link or a reader busy serving a preview does not end the session, and
  the connected-over-Wi-Fi state message names it as the reliable path.

## Firmware install confirmation — 2026-09-05

- The app cannot see the reader's SD card or its update screen, so a staged
  firmware transfer used to end with a caption that was easy to miss and no way
  to know whether the reader actually installed it. `FirmwareInstallCheck`
  fixes that: after a verified firmware transfer the app stores the exact
  `CrossPoint version:` string embedded in the staged image, shows an
  unmistakable "STAGED, NOT INSTALLED YET" result, and on the next connection
  compares it with the reader's reported `version` to say either "Firmware
  installed: running <version>" or "Not installed yet: still runs <old>".
- The reader and the image use the same version format
  (`1.4.1-dev-main-<sha>-w<worktree fingerprint>`), so the comparison is exact.

## Resume on another machine — 2026-09-05

Clone `pocket-daily` and `pocket-daily-firmware` as siblings, then:

1. `xcodegen generate`; iOS tests and the macOS build use the commands in
   `AGENTS.md` (derived data under `.build/`). For hardware runs build the
   signed Debug app: `xcodebuild build -project Pocket.xcodeproj -scheme
   PocketMac -configuration Debug -sdk macosx -derivedDataPath .build/mac-signed`
   and launch `.build/mac-signed/Build/Products/Debug/Pocket.app`. Quit a
   running instance first; `open` only foregrounds an old binary.
2. Reliable transfer path: reader → File Transfer → Join a Network, app →
   Connect (no reader Sync needed). Drop `update.bin`; the app shows an orange
   "Staged — install on the reader" box, and after the reader installs and you
   reconnect, a green "Firmware installed: running <version>" box.
3. State as committed: 36 iOS tests, signed macOS build, and an end-to-end
   app-driven firmware install verified on an X3 over the LAN.
4. Open items: App Store review video and TestFlight remain account-holder
   work; the Sync hotspot is the fallback path only.

## Maintenance rules

- Add only durable decisions, verified baselines, protocol contracts, or
  non-obvious constraints that will help a future session.
- Date mutable observations and name their source of truth.
- Replace stale notes instead of accumulating contradictions.
- Keep troubleshooting logs and one-off session details out of this file.
