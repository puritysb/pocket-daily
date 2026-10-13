# Pocket Daily Project Memory

This is curated, repository-owned context for future work sessions. It is not a
chat transcript or a test log. Prefer current code and release manifests when
they conflict with a dated note below. Per-session evidence lives in
`docs/CURRENT_HANDOFF.md`; everything before 2026-10-13 is archived in
`docs/history/`.

## Product decisions in force

- 2026-09-27 (user): Pocket Daily is a standalone, account-free e-book reader
  AND the X3/X4 companion. Library opens first and works offline; App Store
  category is Books. Decision record: `docs/READER_EXPANSION.md`.
- Reader engine: pinned foliate-js subset in `Support/ReaderEngine`, WKWebView,
  app-only `pocket-reader://` scheme, CSP blocks book scripts. foliate's 100 ms
  turn lock dropped jumps right after a turn; the bridge serializes turns
  before navigation.
- 2026-09-27 (user): KOReader sync is removed from this version (code deleted;
  history before `c594af7`). Do not reintroduce it. KOReader *formats* remain:
  crengine XPointer + start-of-page progress (+ CFI locally) and KOReader
  partial-MD5 document identity (`KOReaderDocumentDigest`).
- Continue Reading never auto-jumps; opening a book alone does not count as
  reading (keeps the saved time so a newer reader place is offered).
- Articles: browser share → local review/edit → EPUB → explicit transfer.
  Direct HTTPS RSS/Atom feeds (≤50, latest 20 entries, refresh on activation at
  most every 5 min); feed links/redirects to local hosts are rejected
  (`docs/ARTICLES.md`). iOS share extension uses an App Group.
- Weather/events: the app composes `ReaderGlance` (WeatherKit for a typed,
  geocoded city — no location permission — plus optional EventKit) and POSTs it
  to the reader. WeatherKit needs the App Service enabled on the App ID.
- 2026-10-13 reading-first defaults: new profiles keep a Reading slot and Sleep
  defaults to Reading Brief; weather, events and vocabulary are opt-in. First-use
  boundaries and firmware-specific guidance: `docs/READER_FIRST_USE.md`. Do not
  recommend Pocket Daily via CrossPoint's unlocker on locked units.
- 2026-10-03 (user): pre-0.x firmware compatibility dropped (done 2026-10-14).
  Kept on purpose: the lineage-1 → 0.x update offer and CrossPoint guidance.
- 2026-10-12 (user): finish X3 + app usability before X4; no new backlog
  features or release work until asked. 2026-10-10 (user): verify on real
  Mac/iPhone/reader rather than simulators where hardware behavior matters.
- Android is a later target; keep reading/sync/library/transfer contracts
  platform-neutral. Not started.

## Repository boundary and collaboration

- App (this repo) and firmware (`../pocket-daily-firmware`) are siblings. The
  firmware owns reader behavior, endpoints, validation and flashing; contracts
  are verified on both sides.
- OpenCode, Claude Code and Codex share this repo. `AGENTS.md` is the only
  instruction file; this file is the shared memory. 2026-09-24: `CLAUDE.md` was
  folded into `AGENTS.md` and must not return (Claude Code reads `AGENTS.md`
  only when no `CLAUDE.md`/`CLAUDE.local.md` exists at or above the cwd).
- Host renderer exception: `Support/PocketUIHost/` holds a host-built,
  hash-pinned XCFramework (`PIN.json`, `PROVENANCE.json`,
  `docs/HOST_RENDERER.md`). It is never a device image. Reimport through the
  firmware importer and record the firmware commit it was built from.
- Firmware SDK changes are reproduced by the firmware's tracked
  `scripts/storage_sdk.patch`; never commit the submodule pointer to a local
  SDK commit.

## Cross-repository contracts (defining docs)

| Area | App doc | Firmware doc |
|---|---|---|
| Reading position, `offerVersion:2` / readerSeq | `docs/READING_PROGRESS.md` | `docs/reading-progress-v1.md`, `docs/reading-sync-ble-v1.md` |
| Transfers, `publicationReceipt:1`, firmware staging | `docs/TRANSFERS.md`, `docs/TRANSPORT_RELIABILITY.md` | `docs/transfer-control-v1.md`, `docs/webserver-endpoints.md` |
| Reader files `readerFiles: 2` (offset pieces) | `docs/READER_FILES.md` | `docs/reader-files.md` |
| Sessions: Same Wi-Fi vs Direct | `docs/SYNC_SESSIONS.md` | `docs/nearby-sync-v1.md` |
| BLE Wi-Fi provisioning | `docs/READER_WIFI_SETUP.md` | nearby-sync docs |
| Profile, cards, content | `docs/CONTENT_EDITOR.md`, `docs/CONTENT_DEPLOYMENT.md` | `docs/pocket-profile-v1.md`, `docs/content-*.md` |
| Glance (weather/events) | — | `docs/pocket-glance-v1.md` |
| Firmware versioning | — | `docs/product-versioning.md`, `docs/release-checklist.md` |
| Live studio (status/preference push only) | `docs/LIVE_STUDIO_DESIGN.md` | `docs/live-studio-v1.md` |

- 2026-10-02: firmware removed UI packs, live frames and the saved screen
  preview. The app decodes only `liveStudio.mode` (required) and `wsPort`,
  subscribes with `{"subscribe":{}}`; there is no frame/pack state in
  `DeviceCore`.
- Status `deviceID` (eight hex digits, same as BLE) is a routing/consistency
  check, not cryptographic HTTP authentication. Registration IDs are pinned per
  reader; additional unidentified readers are refused.
- Bluetooth reading-sync windows open only from Pocket Daily Home and sleep,
  not stock Home/Library/File Browser. Background BLE delivery is OS-controlled.
- Generic transfers require advertised upload/commit; commit writes a durable
  `publicationPending` marker. Pending publication is resolved through a
  same-reader identity probe and receipt query, never by resending bytes.
  Only the latest firmware SD receipt is retained.
- Upload stream: SD-ACK flow control (`uploadStreamWindow:4096`), resume via
  `RESUME <received>`; reader resume state is RAM-only (a reboot restarts at 0).
  Prepared copies + UUIDs live in Application Support/Pocket/Transfers.

## Firmware versions and update flow

- 2026-10-03 (user): Pocket Daily firmware is the 0.x series; every version
  below 1.0 is beta but published as a normal GitHub release marked latest, so
  the reader's own updater (`/releases/latest`) finds it. Tags are
  `pocket-v<version>`; `pocket-v1.0.0-beta.1` is retired; historical `v1.6.6`
  and `v1.7.0-beta.*` are old test releases. `firmwareLineage: 2` since 0.1.0.
- As of 2026-10-13 no `pocket-v0.1.0` tag exists; it waits for an X3 pass of the
  CI-built image. Until then Update reader offers nothing in store builds.
- App: `FirmwareGuidance.minimumRecommended = "0.1.0"`; lineage-1 readers on
  `1.0.0-*` are offered 0.x once (`isBeforeVersionReset`). Release builds use
  `/releases/latest` (stable); DEBUG uses the beta channel (`/releases?per_page=10`,
  pre-releases included). `FirmwareReleaseError.noRelease` covers no usable tag.
- DEBUG builds can also send a local `firmware/update.bin` (Reader → Connection
  → Firmware → Send a local build…); store builds keep official releases only.
- Staging is not installation: the reader validates again and asks for its own
  Confirm. App-side validation checks the ESP32-C3 image structure, segment
  bounds, checksum, digest and Pocket/CrossPoint markers before wireless or SD
  publication. Release check also runs on reader connect (retry floor 60 s,
  refresh after 10 min; disclosed in PRIVACY.md and APP_STORE_REVIEW.md).
- While a sent image waits, the heartbeat polls every 3 s and two misses end the
  session ("The reader left Sync to install …"). Steady heartbeat: 15 s, 6 s
  timeout, failure limit in `ConnectionHeartbeat`.
- Open (needs firmware): on Same Wi-Fi the reader still needs Back before its
  install prompt (`session/end` exists only for the private AP). Update reader is
  unavailable in a Direct session because the download needs internet.
- Developer installation uses the sibling `scripts/dev_pipeline.py` with
  `--flash` within user-authorized scope; never automatic in the shipping app.

## Connectivity architecture (app)

- Find & Connect / explicit Connect checks LAN first; it never changes the Apple
  device Wi-Fi as a side effect. Direct connection (BLE + private AP lease) is
  explicitly chosen and requires other network sessions to finish first.
- `ReaderWorkLane` owns admission, cancellation draining and task ownership for
  all reader I/O (transfers, settings, preview, discovery, verification,
  direct association, quiet BLE exchange). Stale completions cannot release a
  replacement; user work preempts quiet reading exchange.
- Discovery: Bonjour plus a /24–/22 HTTP sweep (`sweepConcurrency` 48,
  `discoveryBudget` 20 s per pass). File Transfer firmware has no mDNS, so the
  sweep is intentional. Same-Wi-Fi auto-reconnect every 8 s
  (`Pocket.reconnectSameWiFi`), same device ID only, held after End Session.
- 2026-10-11: when the saved address is stale, the app's discovery finds the
  reader on a new network without manual IP input (physical pass).
- Multiple readers (2026-10-09): each registration owns its connection, work
  lane, Bluetooth restoration identity, prepared copies, jobs and drafts
  (`ReaderWorkspace`, `ReaderFleet`). Same-Wi-Fi sessions run concurrently.
  Two physical readers at once remain unverified.
- Permissions are requested only by the feature that needs them: no Bluetooth or
  local-network prompt on launch or in demo (`CBCentralManager` is lazy).
  Current-SSID lookup only from Use Current Wi-Fi; Mac saved-password lookup
  stays in the OS keychain permission flow. Credentials are never stored in app
  defaults, logged, or sent over HTTP.
- 2026-10-13 onboarding: pairing has a 90 s deadline with actionable encryption
  errors; Bluetooth readiness is checked before asking an online reader to leave
  Wi-Fi; a single Wi-Fi command's receipt is observed for 90 s without
  replaying credentials; cancelled permission requests ignore late callbacks.

## Reader wake and BLE standby

- Explicit Connect for a remembered bonded reader: LAN first, then BLE
  `WAKE1`/`START_WIFI`, then verifies the same identity on LAN. One command, 20 s
  overall deadline, no retry after an ambiguous acknowledgement. Quiet BLE
  exchange never raises Wi-Fi.
- 2026-10-12: if the pending BLE connection stalls for 8 s, `ReaderWakeConnector`
  cancels it once, waits for the cancel callback, scans for the bonded
  service/identifier and reconnects (3/3 physical pass with injected
  advertising delay). Background reading exchange does not scan. The original
  cable-unplug RF miss remains unexplained.
- Firmware standby (developer `ble_standby` build): low-battery exits are
  distinguished from timeout; charging allows strictly above 5 %, otherwise
  above 10 %. Default/release firmware and X4 have not adopted standby.
- Fresh X3 without settings offers authenticated BLE setup once, with Read
  offline and a five-minute idle exit. Local wake cue replaces the old refresh;
  held input during the panel BUSY waveform is not established.

## Reading continuity

- Without a server: iCloud key-value storage between the user's Apple devices
  and direct exchange with a connected reader (HTTP and BLE share readerSeq).
  Bounded persisted observations reject stale reader observations and suppress
  already delivered local positions; cancelled BLE exchanges record nothing.
- Firmware records page-start XPointers (section cache v133+); the Mac
  cross-check `testFirmwareXPointersResolveToTheSameText` needs the sibling.
- 2026-10-12/13: bidirectional Mac↔X3 continuation passed on generated EPUBs and
  a real Standard Ebooks *Frankenstein* fixture. Short books: verify exact
  visible paragraph characters, not a fixed progress tolerance (page-start
  progress can be far from the target ratio).

## Library, inventory and transfers

- The library keeps book bytes unchanged; TXT/Markdown convert to EPUB on import.
  Imported → transferred → downloaded → reimported EPUB bytes match (2026-10-13).
- `ReaderShelf` shows reader books with "On reader" badges and "Only on your
  reader"; root `crash_report.txt(.1-.3)` and `nearby_ap_log.txt` are excluded
  by exact path (Browse Files still shows them).
- Downloads complete exactly once even when admission fails or the lane cancels
  before I/O; identifier-free diagnostics keep phases/bytes/errors.
- Real Wi-Fi association loss during receive resumes from the same prefix; loss
  after publication recovers the receipt; one send, one publication (2026-10-12).
- macOS can copy supported files atomically to a user-selected mounted SD
  directory; firmware copies there are published as `/update.bin`.

## App UI structure and design

- Library and My Reader are peer destinations. My Reader combines identity,
  retained work and observed files; Reader Settings has Home Screen / Sleep
  Screen / Reading Preferences scopes; Reader Options → Manage Reader owns
  connection, firmware and diagnostics; Readers… → Manage Readers manages
  registrations. The UI says "Reader" until a reader reports its model.
- Appearance and Continue Reading settings live only in Settings (macOS
  Settings window; iOS sheet). App chrome has System/Light/Dark
  (`appAppearance`); reader page themes (Paper/White/Night) are independent.
- Design system: `Sources/PocketDesign.swift`, `Sources/PocketPalette.swift`,
  `docs/DESIGN_SYSTEM.md`. Use `StatusTone` + `PocketPalette.caution/critical/
  signal` instead of system red/orange/green (contrast on paper). Width
  breakpoints are only `wideLayoutWidth` 920 and `splitLayoutWidth` 680. Apple
  title case for buttons/menus/titles; prose naming a button uses the same text.
- Studio edits persist (`ProfileEditStore`) and merge per field (`ProfileMerge`).
- Not done: localization (`.xcstrings`), Icon Composer layered icons.

## Developer pipeline and verified baseline

- Entry point: `docs/DEVELOPER_PIPELINE.md`; full suite:
  `docs/READER_INTERFACE_VALIDATION.md`
  (`scripts/verify_reader_interface.py`). Shared hardware scenarios live in
  `HardwareTests/` and run only with explicit opt-in on signed Debug macOS or
  physical iOS; `ReaderDevelopmentContext` is Debug-only and absent in Release.
- Developer reset paths archive settings, preserve book bytes and are excluded
  from shipping builds. Existing reset archives remain; do not repeat a reset
  blindly. `--onboarding` is Mac/X3 only.
- Latest physical baseline (2026-10-14, Mac/X3 Same Wi-Fi, firmware
  `0.1.0-dev-main-14bf9624-ble-standby-w8e68d8a9`): aggregate
  `.build/interface-runs/20261013T171707-939866/report.json` (firmware run
  `20261013T171736-315400`): 10 interface cases, two real Wi-Fi outages, 14
  screen/sleep/wake captures, real-EPUB bidirectional reading, BLE standby wake.
  BLE-only reading acceptance `20261013T170240-a41674` (see below). Onboarding
  rollback last passed 2026-10-13 (`20261013T131358-21d2ed`).
- BLE-only reading acceptance (2026-10-14): `--continuity-suite --ble-continuity`
  runs every exchange in X3 developer standby through a test-owned
  `ReaderBluetoothLink` (shipping state machine/transport, isolated sync); the
  production Connect wakes the reader back. 8 run-bound legs incl. an unarmed
  control (0 lists/offers); BLE window min heap ~62.7 KB, block 55,284 B.
- Not established by that baseline: X4, expanded physical iPhone, iCloud between
  physical devices, BLE-only exchange outside developer standby (book close,
  wake, pre-sleep windows; iPhone background), optical panel quality,
  image-rich EPUBs, overnight/battery-only standby and current draw, router
  reboot/DHCP change during transfer, two simultaneous physical readers.
- The installed Mac copy at `~/Applications/Pocket Daily.app` is the signed
  sandboxed **Debug** build (local firmware sending exists only in Debug).

## Build, test and capture gotchas

- Signed Debug Mac build for hardware work:
  `xcodebuild build -project Pocket.xcodeproj -scheme PocketMac -configuration
  Debug -sdk macosx -derivedDataPath .build/mac-signed`. Quit a running instance
  first; `open` only foregrounds an old binary.
- UI tests touching Articles or the share extension need the App Group: run them
  ad-hoc signed (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`, as
  `scripts/capture_screenshots.sh` does); otherwise "The shared article storage
  is unavailable".
- Mac store screenshots come from `PocketMacTests` off-screen windows, not UI
  tests (the macOS UI-test runner needs interactive Accessibility permission;
  `ImageRenderer` misses scroll-view contents). A titled window is clamped to
  the visible frame; hosted sheets need their own background. The validator
  rejects byte-identical images within a device class.
- `project.yml` declares both schemes explicitly (the macOS target ships as
  `Pocket.app`, so `TEST_HOST` cannot be derived); PocketMac needs
  `productName: Pocket` or regeneration flips the scheme's product name.
- Testing Release needs `ENABLE_TESTABILITY=YES` (`@testable import Pocket`).
- `scripts/package_app_store.sh` runs `-only-testing:PocketTests`; UI tests must
  not gate distribution builds (a wedged simulator hung packaging for 30+ min).
- `NearbySyncProtocolTests` remains iOS-only (sandbox loopback/shared-radio
  fixtures); `NearbyOnboardingTests` is shared with the Mac target.
- Shared simulators interfere across sessions; use isolated devices/derived data.
- `xcodebuild -exportArchive` on this host needs a system-only `PATH`
  (`/usr/bin:/bin:/usr/sbin:/sbin`); Homebrew rsync breaks the IPA copy.
- Python on this host may be blocked from the LAN; `/usr/bin/curl` works for
  reader status checks.

## Release, App Store and signing

- Release sources of truth: `project.yml`, `appstore/submission.json`,
  `appstore/README.md`, `APP_STORE_REVIEW.md`, `PRIVACY.md`. Bundle ID
  `bound.serendipity.pocket.daily`, team `QF36NDHYHD`, version 1.0.0 build 1,
  manual release, category Books/Education.
- Latest signed IPA + universal sandboxed Mac PKG export: 2026-10-09
  (`.build/app-store/final-20261009-v2/`, hashes in `submission.json`). Later
  product changes (Wi-Fi setup, wake recovery, onboarding) are not in it.
  Nothing has been uploaded or submitted.
- Store-signed products cannot be launched locally (Gatekeeper / `launchd`
  error 163); reaching them requires TestFlight.
- Signing on this host is fragile: the Apple Distribution certificate has
  disappeared before. Restore with Xcode account sign-in, confirm with
  `security find-identity -v -p codesigning`. 2026-10-10: App ID gained
  Access Wi-Fi Information; distribution profiles/IPA need re-export.
- Account-holder work still open: App Store Connect record, upload token,
  review contact, TestFlight, physical X3/X4 review video
  (`account_fields_still_required` in `submission.json`).

## Maintenance rules

- Add only durable decisions, verified baselines, protocol contracts, or
  non-obvious constraints that will help a future session.
- Date mutable observations and name their source of truth.
- Replace stale notes instead of accumulating contradictions; move superseded
  entries to `docs/history/` rather than appending. Keep this file at or under
  about 300 lines, organized by topic, not by date.
- Keep troubleshooting logs, test counts and one-off session details out of this
  file; per-session evidence belongs in `docs/CURRENT_HANDOFF.md`.
- A memory entry must be committed together with the change it describes.
  Uncommitted work is not a verified baseline; when the tree is ahead of this
  file, read the working tree, and when this file is ahead of the tree, treat
  the entry as intent, not fact.

Archive of dated entries through 2026-10-13:
[history/PROJECT_MEMORY-to-2026-10-13.md](history/PROJECT_MEMORY-to-2026-10-13.md).
