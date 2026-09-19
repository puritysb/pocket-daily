# Pocket Daily Project Memory

This is curated, repository-owned context for future work sessions. It is not a
chat transcript. Prefer current code and release manifests when they conflict
with a dated note below.

## Repository split

- App Store app: this repository (`https://github.com/puritysb/pocket-daily`),
  checked out on this host at `/Users/puritysb/git/pocket-daily`.
- Reader firmware: sibling directory `pocket-daily-firmware` next to this clone
  (`https://github.com/puritysb/pocket-daily-firmware`), on this host at
  `/Users/puritysb/git/pocket-daily-firmware`.

The host checkout root moved from `~/github/` to `~/git/` (noted 2026-09-19).
Absolute `~/github/` paths in either repository's older notes are stale;
resolve the sibling repository relative to this checkout.

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

## Release-readiness fixes — 2026-09-06

- Permissions are requested only on Find & Connect: `NearbySyncController`
  creates its `CBCentralManager` lazily on the first scan, and `ContentView`
  no longer probes the LAN in its launch task. Launch and demo mode trigger no
  Bluetooth or local-network prompt.
- The status line carries an explicit `StatusTone` from `PocketModel.post`
  instead of the UI guessing success/failure from wording.
- iOS treats `NEHotspotConfigurationError.alreadyAssociated` as a successful
  join and reports `userDenied` as a cancel with a retry hint.
- macOS SD-card firmware copies are published as `/update.bin` (replacing a
  previously staged image), record the staged version for the install check,
  and show the same orange "Staged" result as the wireless path.
- The firmware confirmation sheet scrolls and offers medium and large detents.
- The App Store screenshot set and ko-KR copy were regenerated to match the
  current interface; `scripts/capture_screenshots.sh` produces the set through
  `PocketUITests`/`PocketMacUITests` (the macOS runner needs ad-hoc signing and
  Accessibility permission). Keywords no longer claim study features.
- Verified on this revision: 40 iOS simulator tests, macOS build, validator.
  Signed Store exports and hardware runs were not repeated.

## Store screenshot pipeline — 2026-09-08

- `scripts/capture_screenshots.sh` regenerates every App Store screenshot from
  the shipping demo UI and needs no special permissions. iPhone and iPad come
  from `PocketUITests` in the simulator; the Mac set comes from `PocketMacTests`,
  a unit test that hosts the real SwiftUI views in an off-screen borderless
  window and asks that window to draw itself.
- The Mac set is deliberately not a UI test: the macOS UI-test runner fails with
  "Timed out while enabling automation mode" unless the Accessibility permission
  is granted interactively, which a script or CI cannot do. `ImageRenderer` was
  tried first and rejected — it renders the studio's backgrounds but not the
  contents of its scroll views.
- Two traps the window path hit, both now encoded in the test: a titled window is
  clamped to the screen's visible frame (capture came out 2880x1688 instead of
  2880x1800), and a directly hosted sheet has no window background of its own, so
  the studio showed through the About card.
- `project.yml` now declares both schemes explicitly; XcodeGen's generated
  PocketMac scheme did not pick up the macOS unit-test bundle, and the macOS
  target ships as `Pocket.app` so `TEST_HOST` cannot be derived from its name.
- The validator enforces per-device counts and rejects byte-identical files in a
  device class. That check exists because the first regenerated iPad set had two
  identical frames: the wide layout already shows the inspector, so the
  "scroll to the inspector" step was a silent no-op.

## Submission-build verification — 2026-09-08

- `scripts/package_app_store.sh` completed on this revision: signed iOS IPA
  (arm64, Hotspot Configuration true, `get-task-allow` false) and universal
  macOS PKG (sandboxed, installer signed), both carrying `PrivacyInfo.xcprivacy`
  and the correct purpose strings, with SHA-256 evidence in
  `release-evidence.json`. Nothing was uploaded.
- The Store-signed products cannot be launched locally, and that is expected:
  Gatekeeper rejects the Mac App Store build and `launchd` fails it with
  `NSPOSIXErrorDomain 163`. Reaching them requires TestFlight or the store.
- What was actually run is the same source in Release configuration: the macOS
  app launched and stayed up, and the suites passed — 40 iOS unit tests, 4 iOS
  UI tests, and the macOS render test.
- `UITests/PocketFlowTests.swift` now pins the first-run behaviour App Review
  sees: no permission prompt on a cold launch (the regression that the deferred
  `CBCentralManager` and removed launch-time LAN probe fixed), demo mode
  populated with every device-mutating control disabled, and the
  independence/privacy notices reachable.
- Running tests against Release needs `ENABLE_TESTABILITY=YES`, because
  `PocketTests` uses `@testable import Pocket`.

## LAN discovery pacing — 2026-09-08

- Symptom, seen while running the shipping build with the reader asleep: tapping
  Find & Connect produced minutes of `NSURLErrorDomain -1001` timeouts in the
  console before the app said anything useful.
- Cause was pacing, not the sweep itself. The nearby set was probed with a batch
  size of 1, so 12 addresses cost 12 x 1.2 s sequentially, and the rest of the
  subnet went 8 at a time at 0.8 s each — about 100 s for a /22 — and the whole
  thing then ran a second time on the retry.
- `PocketModel.probe` is now a sliding window: `sweepConcurrency` (48) requests
  stay in flight, each completion starts the next, and a `discoveryBudget` (20 s)
  bounds one pass. 20 s is sized so a full /22 still fits (~1000 addresses at 48
  in flight and a 0.6 s timeout is ~13 s), so the bound does not cost coverage.
- Measured with `PocketFlowTests.testDiscoveryWithoutAReaderFailsQuicklyAndSaysWhatToDo`,
  which fails the build if a miss takes longer than 60 s to report. Observed ~26 s
  for both passes against a real /22 with no reader on it.
- The candidate list itself is unchanged and still intentional: the X3's File
  Transfer profile has no mDNS, so the app cannot rely on Bonjour.

## Release packaging gate — 2026-09-08

`scripts/package_app_store.sh` runs `-only-testing:PocketTests`. Adding the
UI-test bundles to the scheme put simulator automation on the release path, and
a wedged simulator hung the packaging run for over half an hour in the iOS test
phase with nothing archived. The UI tests still run from the full scheme and
from `scripts/capture_screenshots.sh`; they just no longer gate a distribution
build.

## Signing state on this host — 2026-09-08

The Apple Distribution certificate for team QF36NDHYHD disappeared from the
login keychain part-way through the session. An export at 07:22 KST produced
correctly signed iOS and macOS products; an export at 08:00 KST failed with
`No Accounts` and `No signing certificate "iOS Distribution" found`, and
`security find-identity -v` then listed only an Apple Development identity for
an unrelated team. Archiving still succeeds — only the export step needs the
certificate.

Restoring it is account-holder work: sign in to Xcode with the Apple ID for
QF36NDHYHD (or import the .p12), confirm with `security find-identity -v -p
codesigning`, then re-run `scripts/package_app_store.sh`. The 2026-09-01 note
about "refreshing the Xcode Apple account" describes the same fragility on this
machine.

## Maintenance rules

- Add only durable decisions, verified baselines, protocol contracts, or
  non-obvious constraints that will help a future session.
- Date mutable observations and name their source of truth.
- Replace stale notes instead of accumulating contradictions.
- Keep troubleshooting logs and one-off session details out of this file.
- A memory entry must be committed together with the change it describes.
  Uncommitted work is not a verified baseline; when the tree is ahead of this
  file, read the working tree, and when this file is ahead of the tree, treat
  the entry as intent, not fact.

## Live studio direction — 2026-09-19

- Agreed product direction: the app becomes a live studio for the reader —
  real-time state sync (WS push, STA first), an exact live frame preview,
  and `.uipack` UI/theme packs composed in the app, deployed over the
  existing verified transfer path, and applied on the reader without
  reflashing. The reading path stays native; only chrome becomes
  definition-driven.
- The design is documented and committed, not implemented:
  `docs/LIVE_STUDIO_DESIGN.md` (app architecture, `DeviceSession`/
  `DeviceMirror` restructure, studio UX, host-renderer bridge) and the
  firmware contract `docs/live-studio-v1.md` in the sibling repository.
  First phase is M1 (Core restructure with polling mirror, no behavior
  change); firmware phases are LS-1..LS-4.
- The host-renderer artifact (`libpdui_host.a` copied into
  `Support/PocketUIHost/` with provenance SHA) is an approved, documented
  exception to the no-firmware-binaries rule — host-built and hash-pinned,
  never a device image.

## Multi-agent collaboration — 2026-09-19

- OpenCode, Claude Code, and Codex all work in this repository. `AGENTS.md` is
  the single operational entry point for every agent, `CLAUDE.md` is the shared
  product constitution, and this file is the shared cross-agent memory. No
  agent keeps a private instruction file or separate memory.
- On 2026-09-19 the working tree held verified but uncommitted work dated
  2026-09-06 through 2026-09-09 (direct sessions, LAN discovery pacing, the
  screenshot pipeline, and App Store submission updates) while `origin/main`
  stopped at the firmware install-check change. Dated sections in that range
  describe that pending change set, not a pushed baseline.

## Explicit direct sessions — 2026-09-09

- Find & Connect is LAN-only. Connect directly explicitly authorizes BLE/AP
  handoff; the app no longer changes Wi-Fi as a side effect of LAN discovery.
- Prepared copies and UUID metadata live in Application Support/Pocket/Transfers
  until sent or removed. Same-reader retries keep the UUID, including app relaunch;
  reader reboot can still restart at zero because firmware resume state is in RAM.
- Status adds optional deviceID (same eight hex digits as BLE) and sessionEnd.
  Device ID is a routing/consistency check, not cryptographic HTTP authentication.
  Legacy readers remain usable but cross-session resume and automatic install
  verification are limited without identity. Direct BLE identity can key an upgrade.
- New private AP firmware accepts POST /api/pocket/v1/session/end, rejects active
  uploads, responds before exiting, and excludes status heartbeats from idle time.
  Capability gating preserves older firmware. OS network restoration is best effort.
- Direct sessions skip optional diagnostics; iOS backgrounding cancels the stream
  and retains the queue. Firmware confirmation remains on the reader.
- Physical iPhone/X3 AP, LAN, sleep/resume, and installation sign-off is pending.

- Local verification: 44 iOS unit tests, iPhone/iPad flow tests and screenshots,
  macOS build/render capture, App Store source validator, and firmware default
  build plus 132 host tests. Hardware acceptance cases are tracked in
  `docs/CONNECTIVITY_VALIDATION.md`; local success is not physical sign-off.

- Strict cppcheck passed with the project's 2.11 release compiled natively for
  Apple Silicon. The registry mirror was unavailable and the existing tool was
  Intel-only; the override lives in the firmware's ignored build/native-check.ini.

## X3 installation verified — 2026-09-09

- After user-side installation, live STA /api/status reported
  `1.4.1-dev-main-fa92806c-wf9376b5a`, matching the staged image exactly, with
  a fresh software restart. New deviceID and sessionEnd=false fields were
  present; port 82 and resume remained available. Direct AP and updated iPhone
  app verification are still pending.

## iPhone development install — 2026-09-09

- Paired the physical iPhone 14 Pro Max (iOS 26.6.1); Developer Mode was enabled.
  The current source built with development signing, installed through devicectl,
  and launched as bound.serendipity.pocket.daily. No Store upload was performed.
- The available Apple Development certificate's actual OU is QF36NDHYHD and
  matches this project. Do not infer a team mismatch from the parenthesized
  identifier in the certificate display name. Existing provisioning was sufficient.
- Installation/launch is verified; iPhone LAN/direct-AP transfer remains pending.
