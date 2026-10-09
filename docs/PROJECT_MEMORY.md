# Pocket Daily Project Memory

This is curated, repository-owned context for future work sessions. It is not a
chat transcript. Prefer current code and release manifests when they conflict
with a dated note below.

## Multiple readers — 2026-10-09 (local, not released)

- My Reader → My Readers adds, renames, selects and removes registrations.
  Each reader owns its connection, work lane, Bluetooth restoration identity,
  prepared copies, transfer jobs and profile/card/source drafts. Selection does
  not cancel another reader's work. A retained `ReaderWorkspace` owns pairing
  and draft persistence; only the selected SwiftUI screen is mounted.
- Same-Wi-Fi sessions run concurrently. Registration IDs are pinned and checked
  on discovery/acceptance; duplicate/mismatched readers cannot take over a
  workspace. Direct Wi-Fi requires other network sessions to finish first.
  The first registration preserves legacy files/preferences/Bluetooth identity;
  additional unidentified readers are refused. Removing an idle registration
  leaves library/device files and local draft recovery files intact.
- App-side wire contracts are unchanged; `docs/SYNC_SESSIONS.md` records storage,
  identity and radio boundaries. iCloud/library remain common; reading-position
  nudges reach every registered session. Background BLE delivery is OS-controlled.
- Verified full 541-test regression (one opt-in hardware skip), followed by
  focused registry/concurrency/removal and BLE/reading-engine checks, iPhone/iPad
  draft switching, Mac firmware-XPointer cross-check, and all 19 regenerated
  screenshots/source package validation. Local evidence: `.build/multi-reader/`.
- Signed sandboxed Mac app is installed at `~/Applications/Pocket Daily.app`.
  Existing X3 pairing and drafts survived; the real app reconnected over Same
  Wi-Fi and loaded its inventory. Two physical readers and concurrent physical
  Bluetooth behavior remain unverified; mocked sessions establish isolation.

## Developer hardware scenarios — 2026-10-09

- Shared `HardwareTests/ReaderHardwareTests.swift` runs on signed Debug macOS
  and physical iOS test hosts only with explicit opt-in. It drives the real
  running PocketModel through Connect, fresh inventory and optional BLE standby
  wake, then validates complete root/Books pagination and unique reader cycle
  evidence. `ReaderDevelopmentContext` is a weak Debug-only reference, with no
  remote listener or alternate BLE transport; Release omits it.
- App-side entry point: [DEVELOPER_PIPELINE.md](DEVELOPER_PIPELINE.md), also
  linked from AGENTS.md and connectivity sign-off. Run the sibling firmware
  `scripts/dev_pipeline.py` with `--app "$PWD"` to test this checkout. Canonical
  deployment/recovery instructions remain in its `docs/developer-pipeline.md`.
  Reuse existing local enrollment; close duplicate companion instances before
  reader work. Normal tests skip without
  device I/O; enabled simulator scenarios fail instead of claiming hardware
  proof. Full firmware/app pipeline and two unattended post-install Mac/X3 wake cycles
  passed (13.2/14.2 s reconnect); 134 iOS protocol tests passed, with the hardware
  scenario skipped. Physical iPhone remains a separate opt-in gate requiring a
  provisioned, permissioned and paired app.

## App-requested reader wake — 2026-10-09 (local experimental)

- Explicit Connect first checks LAN, then asks the remembered bonded reader
  to wake over BLE (`WAKE1` / `START_WIFI`) and verifies the same identity on
  LAN. The dedicated foreground transport has no restoration identifier and
  sends no retry after an ambiguous acknowledgement. ReaderWorkLane suspends
  quiet BLE exchange during this operation; quiet exchange never raises Wi-Fi.
- Explicit Connect sheets now start automatically for a remembered reader.
  Manage Reader alone does not. No automatic hotspot or Apple network change;
  initial pairing, permission and saved Wi-Fi remain prerequisites.
- Signed Mac app installed with existing sandbox/pairing intact. Three actual
  Mac/X3 trials woke the experimental reader and reconnected over Same Wi-Fi,
  including standby beyond one minute. Reader recorded actual SDK light-sleep
  time; no current/battery-life claim follows. Firmware default/release and
  X4 have not adopted experimental standby; physical iPhone remains unverified.
- 134 connector/transport/protocol tests passed on iOS Simulator. Final shared
  Connect UI built for iOS and signed macOS; Mac one-click flow was exercised.
  Root file listing/preferences worked, but `/Books` listing returned a separate
  reader error. See `docs/CONNECTIVITY_VALIDATION.md` and sibling firmware
  `docs/ble-standby-review.md` for evidence and exact artifact identity.
- Final firmware `8925b142-ble-standby-wd4168ca4` passed two additional trials
  sleeping directly from Same Wi-Fi, including app restart + one Connect click
  after 80.8 s standby. Final signed Mac and iOS builds passed; the Mac app is
  installed and connected. Five app-wake trials total; no content-transfer or
  battery-life claim follows from those connection results.

## Reader navigation — 2026-10-09 (local, not released)

- My Reader combines identity, retained work and observed files. Library and
  My Reader are peers; Overview/On Reader/Screens/Reading/Device no longer
  occupy separate navigation entries. Reader Settings opens from the reader
  card; Reader Options → Manage Reader owns connection, firmware and diagnostics.
- Reader Settings has Home Screen, Sleep Screen and Reading Preferences scopes.
  Returning within the window retains the selection and drafts; Continue
  editing prefers the last scope with pending edits, including Sleep. Apply
  and Discard still affect only the chosen scope. App reading starts in Library.
- Accessibility text sizes use a scrolling settings surface, an explicit full
  preview action and vertical apply controls. The inventory heading/action
  also stack when needed. UI test navigation recognizes floating iPad tabs.
- Verified 32 focused unit tests, iPhone/iPad offline and draft-return flows,
  four capture/accessibility tests per simulator, and 10 Mac tests (one
  external-EPUB sample skipped). All 19 store images and source validation
  pass. Evidence: `docs/IA_IMPLEMENTATION_REPORT.md`, `.build/reader-ia/`.
  The final signed, sandboxed Mac app is installed and running in My Reader.
- This navigation baseline is now extended by the multiple-reader implementation
  recorded above; firmware transport formats remain unchanged.

## App design system — 2026-10-09 (local, not released)

- `Sources/PocketDesign.swift` centralizes chrome typography, spacing, icon
  slots, action targets and card metrics; `docs/DESIGN_SYSTEM.md` defines their
  use. Paper/charcoal and amber remain the palette. Mac hides the duplicated
  window title and lets the main header use that area, preserving the sidebar's
  traffic-light inset. Library and reader content share a leading alignment.
- Accessible Dynamic Type uses a one-column book row with untruncated titles
  and tabs instead of a fixed-width sidebar. Standard-size layouts keep the
  cover grid/sidebar. Native settings, menus and book/device rendering retain
  their own semantics.
- Verified iOS/macOS builds, six focused iPhone flows, three Mac QA/reading
  tests and a final dark render, plus final large-text captures/tests on both
  iPhone and iPad. Nineteen store screenshots and source validation pass.
  Result paths are in `docs/IA_IMPLEMENTATION_REPORT.md`. The signed Mac app
  was updated and its native titlebar/actions and saved edit entry were checked.
- Status and layout rules (2026-10-09): `StatusTone.color`/`.symbol` with
  `PocketPalette.caution`/`critical`/`signal` replace system red/orange/green,
  whose light-mode text contrast on paper was 1.95–3.15:1 (now 4.7:1 or more).
  Status lines tint only the symbol. `wideLayoutWidth` 920 and
  `splitLayoutWidth` 680 are the only width breakpoints; card-like containers
  use `cardRadius`. The share extension keeps system red because it is built
  without the palette. Usability principles, five screen archetypes and a
  review checklist are in `docs/DESIGN_SYSTEM.md` with `docs/design/*.svg`.
- Applied across the app (2026-10-09):
  - **Labels:** buttons, menu items, screen titles and icon-button names use
    Apple title case (`Manage Reader`, `Send 2 Books`). Prose that names a
    button uses the same text, and UI tests and review notes were updated
    with it.
  - **Status lines:** `PocketStatusLabel` draws status lines.
  - **Selection:** scope and filter menus use pickers, so the current choice
    shows a checkmark. The app root tints iOS switches amber.
  - **Send to Reader sheet:** its actions are pinned to the bottom edge.
  - **Repeated actions:** each now appears once on its screen (inventory
    connect, task reopen).
  - **Confirmations:** they name the books, the reader, or the firmware
    version.

## UX handoff verification — 2026-10-09 (local, not released)

- Reviewed the UX evaluation changes and added explicit UI assertions for
  demo inventory, compact preview enlargement/return, and hiding demo entry
  inside an editor connection. Regenerated the Xcode project and 19 store
  screenshots; source-package validation and local Markdown links pass.
- The share test now taps the remote share cell's visible `activityImageView`.
  The previous container tap left the iPhone share sheet open without starting
  the extension. The revised save/import flow passes on iPhone (iOS 26.5)
  and iPad Pro 13 (iOS 27). An initial cold iPad run also showed an empty system
  share sheet; these passes do not establish that OS startup issue is fixed.
- Verification: 530 unit tests, 25 iPhone flows and 2 QA tours passed in the
  main run; its one share failure passed after the tap correction. Two updated
  iPhone regression tests and four iPad flows pass. macOS build and 10 tests
  pass; the optional external-EPUB sample test is skipped. Details and local
  result paths are in `docs/IA_IMPLEMENTATION_REPORT.md`.
- Only `main` and the primary checkout were present, with no stashes or stale
  worktree records. No push, Store action, or physical-reader test was performed.

## UX evaluation loop — 2026-10-08 (local, not released)

- Scenario renders (Mac QA tests, new `UITests/PocketQATourTests` iPhone tour
  of first run without a reader and demo) found: a sparse Mac Overview, an
  unlabelled "Continue Reading settings" link, demo offered inside book/editor
  connections, a demo identity warning, a cramped iPhone Library header, a
  tiny compact preview and an empty demo On Reader. All fixed; details and
  evidence in `docs/IA_IMPLEMENTATION_REPORT.md` (2026-10-08 section).
- `--ui-test-fresh-library` now also isolates prepared transfers and job
  records (DEBUG only). Orphan prepared copies from earlier runs had been
  recovered as "Paused" book transfers in every fresh-library UI test.
- The share-test failures observed in this loop were followed up on 2026-10-09
  above; the corrected tap now passes on both tested models. the floating-tab detection limitation was corrected in the 2026-10-09
  navigation update above. The 11-inch model itself has not been reverified.

## IA and UX integration — 2026-10-08 (not released)

- Library and My Reader remain equal first-class destinations. Library owns
  ordinary book/text creation; On Reader owns observed files and SD space.
- Home/Sleep layout editing has one apply action. Shared cards and weather/
  calendar open dedicated editors, preserving drafts and parent scope through
  connection. Reading uses model/orientation-specific button diagrams.
- Selected-book tasks retain content through Wi-Fi/SD destination selection;
  SD outcomes do not erase uncertain wireless publication. Recovery returns
  to the actual task owner. Mac Overview no longer duplicates sidebar menus.
- The 2026-10-06 verification baseline is documented with exact evidence and
  reruns in `docs/IA_IMPLEMENTATION_REPORT.md`: 529 iOS unit tests, 44 final
  focused tests, 26 iPhone and 6 iPad flows, Mac checks with two harness fixes
  rechecked, and 19 refreshed store captures. Physical radio/SD/firmware
  acceptance remains pending; this is not an App Store release.
- This integration records the formerly uncommitted Settings/Studio and IA
  work alongside the companion connectivity commits. Product contracts and
  remaining scope are in `docs/PRODUCT_IA.md` and `docs/PRODUCT_UX_SPEC.md`.

## Companion connectivity revision — 2026-10-05 (local, not released)

- ReaderWorkLane consolidates admission, cancellation draining and task ownership;
  stale completions cannot release a replacement. Automatic BLE yields to this
  lane; manual pairing retains its existing radio handoff controller.
- Pairing, READ1 support and completed BLE exchange are separate. The app persists
  support and last completion, shows waiting/errors and uses matching-reader HTTP
  readSync diagnostics for firmware memory/battery/bond gates. No gate was lowered.
- `publicationReceipt:1` resolves pending publication through same-reader identity
  probe and receipt query, without sending bytes or commit again. Only the latest
  firmware SD receipt is retained; missing/corrupt receipts remain unknown.
- Official firmware can be downloaded/validated before Direct connection, then
  explicitly sent after acknowledgement. Both capable LAN/AP sessions end after
  firmware publication so the reader can ask for installation. No automatic flash.
- `offerVersion:2` / readerSeq is shared across HTTP and BLE. Bounded persisted
  observations permit causal rereading, retry failed unchanged proposals, reject
  stale reader observations and suppress already delivered local positions.
  Canceled/forgotten Bluetooth exchanges do not record completion.
- Contract sources: `docs/TRANSFERS.md`, `docs/READING_PROGRESS.md`, and sibling
  firmware nearby-sync/reading-progress documents. The firmware release checklist
  has separate pending X3/X4 gates. Host/simulator builds are not hardware proof.
- Final local verification: 487/487 iOS unit tests, iOS/macOS builds, 430/430
  Mac firmware XPointer cross-checks and App Store source-package validation
  pass. The screenshot script regenerated 19 iPhone/iPad/Mac images in an
  isolated source snapshot; firmware-card and connection captures were inspected.
  Logs/assets are under `.build/connectivity-verification/`; original-checkout
  Mac card/XPointer logs are `.build/connectivity-*.log`. Shared-simulator
  interference required isolated devices. A stale layout-test expectation in
  the first snapshot was refreshed from the other session before the clean run.
  That session subsequently changed ProfileStudioView; these checks establish
  this connectivity revision, not acceptance of its later Studio changes.
- Local work shares the checkout with another session's Settings/Studio changes;
  those edits are preserved. No push, release or physical installation.

## Sleep WAKE control — 2026-09-30

- Screens → Sleep stages `sleepWakeIndicator` with reading preferences. Offline
  and demo default on; GET absence/unknown values mean unsupported, with an
  explanation and no POST key. Merge/discard preserve the capability boundary.
- The sibling firmware persists the default-on setting in the Display registry;
  GET advertises it and POST validates it atomically, including rollback on save
  failure. It applies on the next sleep frame, including Brief, cover/custom,
  transparent and Quick Resume modes. See sibling `docs/nearby-sync-v1.md`.
- The rebuilt host ABI adds `pdui_render_sleep_brief` options for WAKE and cover;
  legacy ABI behavior remains unchanged. Both app toggles update preview pixels.
  The shared cue painter anchors to X3's top / X4's upper-right power switch;
  portrait Brief content reserves its area to protect cover-free reading progress.
- Verified 868 firmware host tests and a warning-free default build. Static RAM
  remains 69,912 B; flash is 6,410,009 B (+3,722 B versus the preceding appearance
  build). Strict cppcheck retains the same existing 2 medium/210 low findings.
- macOS Release installed locally; UI toggle, device position and non-overlap
  checked in the installed app. iOS preferences/renderer tests and the toggle/
  discard UI flow passed. Mac tests: 11 run, 2 optional-fixture skips, zero failures.
  All 19 store captures regenerated (Mac refreshed after final inset change) and
  package validation passed. No firmware was installed; physical panel QA pending.

## Installing unreleased firmware from the app — 2026-10-03

- User decision: development builds (`#if DEBUG`) can send a local firmware
  image; store builds keep official releases only (docs/TRANSFERS.md). Reason:
  as of 2026-10-03 no release the app accepts exists (`/releases/latest` is
  `v1.6.6`, `pocket-v1.0.0-beta.1` is retired), so Update reader offers nothing
  until `pocket-v0.1.0` is tagged, and the tag waits for an X3 pass.
- Use: signed Debug Mac build (see "Resume on another machine"), reader in Sync →
  Same Wi-Fi, Reader → Connection → Firmware → Send a local build…, choose the
  sibling `firmware/update.bin`, then Back and Confirm on the reader.
- Hardware (user, 2026-10-03): the signed Debug Mac build sent the local
  gh_release 0.1.0 image (built from `67828475`, SHA-256 `8fa5f4a9…`, not the
  CI image) to X3 `5B09AF70` over Same Wi-Fi; the reader installed it after
  its own Confirm and the app confirmed the version on reconnect.
  `/api/status` afterwards: `0.1.0`, `firmwareLineage: 2`, no crash report.
- While a sent image waits, the heartbeat polls every 3 s and two misses end
  the session with "The reader left Sync to install …" (it was 15 s × 5, so the
  app kept showing the reader as connected during flashing). The Firmware card
  keeps the sent version for the last reader until it reports back. This part
  is unit-tested only.
- The release check also runs when a reader connects (retry floor 60 s,
  refresh after 10 min; PRIVACY.md, the public privacy page and
  APP_STORE_REVIEW.md say so). `FirmwareReleaseError.noRelease` covers historical
  `v…` tags, retired betas, an empty list and a stable-channel 404, shown as
  "No Pocket Daily firmware update has been published yet." Unit-tested only.
- Open, needs the firmware session: on Same Wi-Fi the reader still needs Back
  before its install prompt. `session/end` is registered only for the private
  AP (`PocketEndpoints.cpp`, `POCKET_SYNC && apMode`). Proposal: after a verified
  `/update.bin` commit, advertise a session end for STA too and let the app call
  it, so the reader restarts into its prompt and one Confirm remains. No
  flashing without Confirm; needs a status capability and a new firmware release.
- Also open: Update reader is unavailable in a direct session because the
  download needs internet; a pre-downloaded image would lift that.

## Firmware 0.x series and saved studio edits — 2026-10-03

- User decision: development firmware is `pocket-v0.1.0` (no suffix); every
  version below 1.0 is beta, published as a normal GitHub release marked latest
  so the reader's own updater (`/releases/latest`) finds it; 1.0.0 is the first
  stable release. Before this, `/releases/latest` returned the historical
  `v1.6.6`, so the reader and the app's stable channel found nothing.
- Firmware PR #19 merged 2026-10-02 (`a96170e1`): embedded 0.1.0,
  `firmwareLineage: 2`. As of 2026-10-03 no `pocket-v0.1.0` tag exists and
  `/releases/latest` is still `v1.6.6`; the tag follows a short X3 pass of the
  CI-built image (firmware session). The reader on lineage 1 must take 0.1.0 once
  through the app; its own updater cannot see a lower number.
- App: lineage-1 readers on `1.0.0-*` builds are offered 0.x once
  (`FirmwareGuidance.isBeforeVersionReset`); `pocket-v1.0.0-beta.*` is retired;
  below 1.0 shows "(beta)"; minimumRecommended 0.1.0.
- User decision 2026-10-03: compatibility with older firmware (pre-0.x builds,
  "Nearby Sync"/"Join a Network" names, removed status keys) need not be kept.
  Legacy branches and "on older firmware" copy may be removed; not yet done.
- Studio edits persist (`ProfileEditStore`) and merge per field
  (`ProfileMerge`); see docs/CONTENT_EDITOR.md.

## App cleanup after firmware PR #8–#10 — 2026-10-02

- Firmware removed UI packs, live frames and the saved screen preview. The app
  now decodes only `liveStudio.mode` (required) and `wsPort`, subscribes with
  `{"subscribe":{}}`, has no frame or pack state in `DeviceCore`, and dropped
  `screenPreview*`. The hardware parity test (`dev/capture`) was deleted.
- PocketUIHost re-imported from firmware main `f1451016` (Home label "Home").
- Bluetooth reading-sync windows open only from Pocket Daily Home and sleep,
  not stock Home/Library/File Browser.

## Device-centric IA, phase 1 — 2026-10-01

- Decision record: `docs/READER_EXPANSION.md` 기기 중심 구조. Sidebar: Library
  (Books, Articles) then Reader → Connection (with status), Screens, Files.
  iPhone: Library and Reader tabs; Reader pages are a segmented control
  (`device-pages`). The UI says "Reader", never a fixed model: the model name
  appears only once a reader reports it. `StudioSection` rawValues
  Reader/Screens/Files; UI tests call `open("Reader" | "Screens" | "Files")`.
- `DeviceSnapshot` (`Sources/Core/DeviceSnapshot.swift`) maps CrossPoint status
  and Bluetooth pairing to capabilities; `PocketModel.device` is the shared state.
- Same Wi-Fi reconnect: `PocketModel.reconnectRememberedReader()` every 8 s from
  ContentView (skipped under XCTest), probe outside the reader lane, same
  device ID only, held after End Session until the reader stops answering.
  Setting key `Pocket.reconnectSameWiFi`.
- Phase 2 (app only) is implemented: `ReaderInventory`/`ReaderShelf`
  (`Sources/Library/ReaderShelf.swift`), "On reader" badges, "Only on your
  reader", direct "Send to reader" while connected. Phase 3 app side
  (`Sources/Library/ReaderFileDownload.swift`, Add to Library for EPUB) follows
  firmware PR #12's contract (`readerFiles: 2`, offset pieces); firmware side not
  implemented yet, so no hardware verification. Joint X3/X4 check when it lands:
  1 MB and 20 MB EPUB byte-identical over both bearers.
- UI tests that touch Articles or the share extension need the App Group, so run
  them signed ad hoc (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`, as
  `scripts/capture_screenshots.sh` does). With `CODE_SIGNING_ALLOWED=NO` they fail
  with "The shared article storage is unavailable" (verified 2026-10-01).

## Settings placement — 2026-10-01

- Appearance and Continue Reading live only in Settings: macOS Settings window
  (⌘,, tabs General / Continue Reading) opened from the sidebar's Settings row;
  iOS one sheet from the sidebar (wide) or the Library header gear (compact).
  The Library ⋯ menu and Device's Appearance picker were removed.
- Bluetooth reading-sync pairing moved to Device (`ReaderBluetoothPairingCard`).
  The reader advertises only after Sync → Direct connection; the Sync button
  itself opens a menu, so hints must name Direct connection.
- Hardware (user, 2026-10-01): the Mac Release build paired an X3 from the Device
  card after the Mac forgot a stale `Pocket-AF70` bond
  (`CBError.peerRemovedPairingInformation`; the reader keeps two bonds). A
  background BLE place exchange after pairing is not yet verified.

## Appearance selection and Home cover layout — 2026-09-30

- App chrome has a persisted System/Light/Dark choice (`appAppearance`). Reader page themes
  remain independent; closing a book restores the app choice.
- The sibling Home painter fits a 2:3 cover slot into a stable metadata column
  for Daily Panel top/bottom/off. Actual bitmap aspect ratios are preserved;
  their border follows the fitted image. Host preview uses the shared no-art
  book illustration rather than a stretched hatch. No profile/wire change.
- The app imports the rebuilt, provenance-verified host artifact. Physical X3/X4
  rendering requires the corresponding firmware update; app installation alone
  does not change the reader. No firmware was installed by this change.
- Validation: 863 firmware host tests (including both geometries, four rotations,
  and three panel placements), warning-free default firmware build, Mac tests,
  iPhone reader UI flow, all 19 regenerated store captures with package validation,
  and actual installed Mac appearance/panel controls.
  Full strict cppcheck 2.20 remains failing on existing findings (including
  `HttpDownloader.cpp` copy-constructor/assignment warnings); no suppression or
  unrelated source changes were introduced to hide them. Physical panel QA pending.

## Appearance refresh — 2026-09-30

- `Sources/PocketPalette.swift` owns the app palette as adaptive colors
  (warm paper in light mode, warm charcoal in dark mode); the app no longer
  forces `.light`. The reader page keeps its own Paper/White/Night themes.
  `AccentColor` (amber, with a dark variant) is the global accent, so iOS tab
  bars, links, toggles and checkboxes match the icon and the Mac sidebar.
- Value bars use `PocketBarProgressStyle` (`.pocketBar`) on both platforms
  because the AppKit indicator ignores `tint` and vanished on paper.
- `scripts/generate_app_icons.swift` renders macOS slots on the Big Sur grid
  (824-pt rounded shape on a transparent 1024 canvas) and a thicker-stroke
  variant at 64 px and below; iOS slots stay opaque squares.
- Symbols: Device tab is `rectangle.portrait.inset.filled`, Connection uses
  `antenna.radiowaves.left.and.right` (subscriptions keep the dot variant),
  Files uses `tray.full`, so no two cards on one screen share a symbol.
- Store captures: the Mac window is made key with `controlActiveState .key`
  (switches still draw inactive; see `appstore/screenshots/README.md`), and
  the simulators are pinned to `en_US` before boot. `testRendersDarkAppearance`
  attaches dark QA renders that the publish step skips.
- Flow polish from the QA renders (`testRendersUserFlowStates`): the Text &
  Page sheet is a grouped form with a Done button on macOS; Articles rows share
  the Library's 1100-pt measure and 24-pt gutter; the Firmware card stays
  neutral until a reader is connected instead of showing a failed update check;
  the Library shows an add-books hint until the first own book arrives.
- Not done: localization (no `.xcstrings`; `appstore/metadata/ko-KR` exists),
  and Icon Composer layered icons for iOS 26/macOS 26.

## Firmware product version migration — 2026-09-30

- Pocket Daily firmware starts product version `1.0.0` on CrossPoint 1.6.5.
  Official tags now use `pocket-v...`; historical `v1.6.6` and
  `v1.7.0-beta.*` remain old test releases. The firmware contract is in
  sibling `pocket-daily-firmware/docs/product-versioning.md`.
- The app accepts only product release tags for Update reader. It recognizes
  unmarked historical `1.6.6` and `1.7.0` reader versions as migration
  candidates, including their beta/dev builds; new firmware reports
  `firmwareLineage: 1` so future versions with the same numbers are distinct.
  Old firmware cannot retroactively discover the new version through its own
  updater. Physical installation still requires reader confirmation.

## BLE integration and review — 2026-09-30

- `codex/ble-sync-review` integrates held app BLE `e4751d3` onto `c22df41`;
  firmware counterpart is based on `ee188fe7` plus held BLE `68a77147`.
  This change contains the reviewed integration. GitHub PRs/releases record
  publication state; physical BLE acceptance remains pending.
- Fixes serialize early END against the READ_LIST write acknowledgement, count
  only persisted OK offers, bind demo before launch, and yield synchronously to
  explicit Nearby Sync and the existing HTTP/user-work lane (including drain).
  Restored non-selected connections and failed/cancelled Nearby discovery are
  cleaned up. Reading-sync traces no longer include raw status or reader IDs.
- `docs/READING_PROGRESS.md` records the contract and OS-controlled background
  behavior. Firmware `docs/ble-sync-review-2026-09-30.md` records acceptance:
  96/40 KiB startup gate deliberately skips the old ~83 KB Home case; current
  X3/X4 actual exchange, heap, bonds, Wi-Fi handoff and sleep remain unverified.
- Validation: 439 iOS unit tests (31 BLE), 2 BLE/permission UI tests, macOS
  build/tests and 430/430 firmware XPointers pass. All 19 store screenshots
  regenerated/inspected; only four iPad status-bar date differences arose and
  were omitted. App Store source validation and renderer artifact verification
  pass. Logs/captures are in ignored `.build/ble-review/`.

## Repository split

- 2026-09-30 Firmware integration follow-up at `ee188fe7`: imported a freshly
  built/verified Apple host renderer (`apple-host-nx6umpg9`; exact hashes in
  `docs/HOST_RENDERER.md`), including Pocket Reader's Articles action. ABI/header
  unchanged; existing Swift/test changes preserved byte-for-byte. No transport
  changes needed: BLE/upload/reading contracts remain v1 and firmware adapts
  app font-size slots 0..3 to point sizes. iOS 408/408 and Mac tests pass; all
  19 screenshots regenerated and inspected (5 content changes retained, date-only
  changes omitted); App Store source validator passes. Previous renderer backed
  up by importer. Firmware source and physical devices were not modified; physical
  preview parity and the earlier server-side target/receipt follow-ups remain open.

- 2026-09-29 App-side integration hardening: quiet reading exchange now owns the
  shared operation lane (preemptible by user work, cancelled/drained on transitions);
  iOS restores foreground state before nudging reading sync. Settings saves re-probe
  known device identity. Generic transfers require existing Pocket upload/commit
  advertisements; commit writes a durable `publicationPending` marker and unknown
  outcomes cannot be blindly resumed. Preview compares font family/size and says
  reader layout rather than exact match. iOS 408 unit tests and Mac build pass;
  Mac firmware XPointer check 430/430. iPhone UI 22/22; iPad 17/22 initially,
  all 5 failures pass after simulator restart without code changes. Screenshot
  regeneration (19 captures, date-only differences omitted), Mac tests and App Store
  source validation pass. No firmware protocol change or hardware
  acceptance. Server-side target/CAS, publication receipts and renderer identity
  remain joint follow-ups in `docs/APP_FIRMWARE_INTEGRATION_REVIEW.md`.

- 2026-09-29 App/firmware integration review at app 2757e805 / firmware ccc601c5:
  `docs/APP_FIRMWARE_INTEGRATION_REVIEW.md`. Source review identifies quiet
  reading exchange outside operation ownership, foreground nudge ordering,
  preferences without target identity, uncertain file-commit outcomes, missing
  commit capability admission, and preview parity overstatement. Recommendations
  at that review stage; follow-up implementation is recorded above. Initial iOS unit tests 400/400, Mac firmware
  XPointer check 430/430, renderer artifact verification and 2 Python tests pass.
  Hardware and release validation were not rerun.

- 2026-09-29 Continue Reading with the reader: automatic Wi-Fi exchange with the
  last reader (same device ID, 1.5 s probe of its last address on app activation,
  book open/close); opening a book no longer counts as reading (keeps the saved
  time, so a newer X3 place is offered as "Continue from X3"; X3-verified).
  Exact page positions from firmware v133 verified on the X3. Reading sync over
  Bluetooth is held on branch feat/ble-reading-sync (not on main): the reader's
  window opened but the iPhone never registered the reader in the field test.
- 2026-09-29 Signing restored on this Mac: Xcode's account issues profiles
  again (`-allowProvisioningUpdates`). iOS/Mac development profiles include
  iCloud key-value storage, so the App ID has the iCloud capability; the app is
  installed on the paired iPhone 14 Pro Max. App Store export from c4eea1a is
  signed and verified (appstore/submission.json). Firmware v1.7.0-beta.2
  (pre-release, 17828ba2) is published for the app's beta channel.
- 2026-09-28 App layout: Library (with Articles) first, then Screens (Home/
  Sleep/reading settings), Device (connection, files, firmware), Weather and
  Calendar as separate sections with Apple Weather attribution. The Mac reader
  opens inside the main window. Articles can follow direct HTTPS RSS/Atom feeds
  (≤50, latest 20 entries, refresh on activation at most every 5 min or on
  demand, no background delivery, no pruning); feed links/redirects to local
  hosts are rejected (docs/ARTICLES.md). Local: 398 unit, 22 UI, 7 Mac tests.
- 2026-09-28 X3 reading accepted on firmware bc158e02 (user: much faster; no
  freeze over 30+ pages; lastBuildError none). Still pending on hardware:
  X3→iPhone→X3 landing accuracy and signed iCloud between Apple devices.
- 2026-09-27 KOReader sync removed from this version by user decision (hidden,
  code deleted; history before c594af7). Continue Reading = iCloud KVS + reader
  exchange only. Previews use the PocketSymbols fallback (firmware 75df8f0e).
  On this Mac Python cannot reach the LAN; stage firmware with /usr/bin/curl
  (/upload to a hidden .part, then /api/pocket/v1/commit), see CURRENT_HANDOFF.
- 2026-09-27 Firmware feat/reader-support (host-verified only): advance-cache
  LRU + block reads for large alphabets, invisible/emoji-cluster handling,
  OFL PocketSymbols fallback font (bundled in the app, sent to
  /.fonts/PocketSymbols/, used after reader restart), reading-progress v1
  (docs/READING_PROGRESS.md). App↔firmware XPointers cross-checked both ways
  (258/258, 15/15, 114/114). Wireless .cpfont transfers now go to
  /.fonts/<family>/ like the SD copy. X3/X4 acceptance pending.
- 2026-09-27 Sync without a server: iCloud key-value storage (same Apple ID)
  and direct reader exchange (docs/READING_PROGRESS.md, firmware
  `readingProgress: 1`). Verification without hardware: Mac off-screen reader
  tests incl. real EPUBs. foliate's 100 ms turn lock silently dropped jumps
  right after a turn; the bridge now serializes turns before navigation.
- 2026-09-27 Product direction changed (user decision): Pocket Daily is a
  standalone, account-free e-book reader AND the X3/X4 companion; Library is
  the first screen. Renderer: pinned foliate-js subset in Support/ReaderEngine
  (WKWebView, app-only `pocket-reader://` scheme, CSP blocks book scripts).
  Positions: KOReader XPointer + percentage (+ CFI locally); document identity:
  KOReader partial MD5 (offset 0 first, matches firmware and KOReader).
  Continue-reading suggestions never auto-jump. Android is a
  later target with platform-neutral contracts. Decision record and contracts:
  docs/READER_EXPANSION.md. Store category moves to Books. Local tests/builds
  pass; X3/X4 continuity is unverified.
- 2026-09-27 Reader resources/files: RAM usage replaces routine memory warnings;
  refreshable SD usage and Sync folder browse/reading-file delete require
  `readerFiles: 1`. Prepared content shows its SD destination. Old firmware
  remains usable without invented usage values. Contract: docs/READER_FILES.md.
  Identity/path/cursor validation and deletion confirmation are covered locally;
  X3 installation and SD file-management acceptance remain pending.

- 2026-09-27 Host renderer imported from the reviewed sibling source snapshot
  (see Support/PocketUIHost/PROVENANCE.json and PIN.json). Includes shared
  Home/Brief font fixes. Artifact verification, renderer tests and both
  platform builds pass; provenance is rebuilt against sibling commit
  b818e819 after SD-management consolidation. No hardware acceptance is implied.
- 2026-09-27 Articles and EPUB: browser sharing → local review/edit → EPUB
  preparation → explicit SD transfer → reader library and user-controlled
  deletion. iOS share extension uses an App Group; macOS has the in-app library.
  Contracts: docs/ARTICLES.md and docs/EPUB_ENGINE.md. A prepared article is
  retained when the reader lacks articleLibrary support. The long-section X3
  freeze seen that day was fixed in firmware (see the 2026-09-28 entry).
- 2026-09-26 Firmware beta channel: DEBUG builds use
  `FirmwareReleaseSource.Channel.beta` (GitHub `/releases?per_page=10`,
  newest non-draft usable release, pre-releases included) and offer any other
  build of the same or a newer x.y.z; store builds keep `/releases/latest`
  and the strict newer-only rule. Pre-releases come from `v<version>-beta.<n>`
  tags (sibling docs/release-checklist.md). Same repository path check and
  image/version validation as stable.
- 2026-09-26 UI/UX redesign (local build and simulator tests only): the studio
  is organized around the reader's two screens. A Home | Sleep switch above the
  canvas picks the screen; its modules (Home pages, sleep sections) are switched
  on with a switch and dragged into order (`ModuleList`, `ReorderableList.swift`,
  one shared drag record so lists never reorder each other). My cards open
  under their Home page as a draggable card list. Updated 2026-09-27:
  Home controls come first, then compact book/article text size with an
  illustrative reading preview. Button mapping is not exposed; loaded values
  are preserved. Offline drafts survive disconnect and merge untouched fields
  on connection. Apply to reader sends explicitly; Discard Edits confirms local
  layout/reading reset while retaining card edits. The logo header has no
  redundant Home & Sleep label. Connection/files remain in Reader; Prepare
  content replaces Add. Current screenshots cover iPhone/iPad/Mac. Related
  tests 15 unit + 1 UI pass; both platform builds and store validation pass.
  Sync Home/Sleep presentation is implemented (sibling
  docs/pocket-screen-present-v1.md), with X3 wa4be8509 returning
  rendered three times and user screen confirmation. Sync covers are deliberate
  placeholders. X4/direct hardware acceptance remains open.
- 2026-09-27 Firmware UI: once-per-launch GitHub metadata check outside demo
  and direct sessions; release version/date and one explicit update action.
  Local firmware import is removed. Download, validation and staging are
  cancellable; content and firmware queues are separate, UUID temporary-file
  cleanup waits for transfer completion and retains failed cleanup for retry.
  The reader still confirms installation; release date is not installation date.
  Contract: docs/TRANSFERS.md. Physical cancellation acceptance remains open.
  Earlier beta.1 download→app validation→reader installation was reported
  successful by the previous session; it does not validate the new cancel UI.
- 2026-09-25 Weather and events from the app (firmware 47a363f8, sibling
  docs/pocket-glance-v1.md; verified on X3 2026-09-26): the firmware dropped the AgentDeck daemon; the app composes ReaderGlance
  (WeatherKit forecast for a user-typed city geocoded with CLGeocoder — no
  location permission — plus today's EventKit events when turned on) and POSTs
  /api/pocket/v1/glance on connection (cache only, no internet needed), after
  a weather refresh, and with each Send. Status flag pocketGlance: 1. Provider
  and monitoring Home items are retired (dropped on load, never offered).
  Needs the WeatherKit capability/App Service enabled on the App ID (account
  holder) before WeatherKit returns data; Apple Weather mark and legal link
  shown next to the city. Privacy policy and store copy updated. Home no
  longer shows the "WI-FI OFF / SYNC" band; sleep timeout range is 1–31
  (31 = never).

- 2026-09-25 My cards and cleanup: the Cards tab became "My cards" inside Home
  & Sleep (QR codes from text/links via CoreImage, images from HTTPS links,
  Card preview surface, Load from reader); reader settings moved into Home &
  Sleep with one Send (sendReaderLayout: profile + settings, then cards when
  their revision differs from readerContentRevision). Removed: theme-metric
  inspector and .uipack encoder (firmware contract kept), reader-screen
  capture and live-frame fetching (unused downloads of 50-128 KB per event or
  connection), LIVE/POLL badge, JSON card import/export, Auto-send. Files adds
  "Write text to read" (.txt) and lists TXT/MD/XTC. Needs firmware with
  `word`/`card` and pdui_set_cards (firmware 4b5f37f9).

- 2026-09-25 Load cards from the reader: Cards shows "Load cards from the
  reader…" when status has contentRead: 1 (firmware docs/content-read-v1.md).
  PocketModel.loadReaderCards reads content/state then chunked
  /content/file reads in the reader lane; ReaderContentPull verifies manifest
  SHA == revision, canonical manifest/card bytes and each file hash; the
  editor's import review (prepareImport(_:sourceName:)) gates Replace.
  ReaderContentPullTests cover goldens, chunking and integrity failures. Not
  exercised on a reader.

- 2026-09-25 U4 studio on every platform (firmware e81427dc renderer): Home & Sleep
  first, then Cards, with the Reader inspector (connection, files, reader
  settings, folded Advanced = theme metrics + diagnostics, About & Privacy
  last). Wide (>= 920 pt): header tabs + 320 pt inspector; canvas/controls
  stack below 720 pt of studio width. Compact: three tabs (Home & Sleep,
  Cards, Reader). iOS ContentEditorSheet retired (card studio everywhere,
  autosave + single Send + Auto-send); preview font notices moved to About.
  Screenshot sets: iPhone 01-home-x3/02-sleep-x3/03-cards/04-reader, iPad
  01-home-x3/02-sleep-x3/03-cards/04-home-x4, Mac 01-home-x3/02-cards/
  03-home-x4. Store copy (en-US, ko-KR), review notes and TestFlight plan
  describe the Home & Sleep editor and "Try Demo".

- 2026-09-25 P1-3 (firmware 8e6e75a4; no reader): the Home & Sleep canvas shows
  the firmware Home/Daily Brief painter output via new host ABI calls
  pdui_render_home/pdui_render_brief (ABI stays 1) with labelled sample data;
  schematic fallback when the renderer is unavailable or sleep mode is the
  reader's own screen. HostRendererBridge.nativeProfile maps PocketProfile to
  the firmware record IDs; LayoutPreviewModel keeps the last frame. 294 unit
  tests pass (3 new); the Mac canvas was checked in an offscreen capture.
  Pixel tuning against a device capture and golden hashes remain.

- 2026-09-25 P2: Mac studio tabs Cards | Home & Sleep. The Home & Sleep editor
  reads the reader profile once per connection (status pocketProfile: 1),
  edits a draft (ordered toggles for Home items and sleep sections, daily
  word, weather bottom/top/off, next event, sleep mode) on a labelled layout
  schematic, and sends the whole document with generation CAS; 409 reloads.
  PocketProfile/ReaderProfileState mirror the firmware rules and refuse
  unknown IDs. 288 unit tests pass (6 new). The store set stays at three Mac
  screenshots (validator/submission.json); a Home & Sleep screenshot would be
  a separate release-package decision. Physical Send from the app not yet
  exercised.

- 2026-09-25 P1-1: the studio previews with the reader's resolved display state
  (ReaderDisplayState, one sequential GET per connection and after pack
  apply/revert; 404 = labelled Lyra reference). Hardware parity on X3: host
  render of the gen7 card equals the captured reader frame (0 of 418,176
  pixels; a "Back" label control differs by 600). The tested reader uses the
  classic theme and "« Back", so the previous Base/English preview was wrong
  there too. 282 unit tests pass. Found while testing: deleting the last card
  is autosaved with no undo, and cards on the reader cannot be pulled back
  into the app (tracked in NEXT_STEPS).

- 2026-09-24 repeated Apply unblocked by sibling firmware (TIME_WAIT purge in
  Sync; see its PROJECT_MEMORY and sync-route-memory.md). Actual Mac app edits
  on X3 w0482f45b: gen4 rendered 17,524B/8,180B, same-session gen5 rendered
  20,428B/13,300B (driver receipts). A user test showed three "Apply" buttons
  were confusing. Mac UX step U1: content editing is the main window
  (ContentStudioView) with the exact host-rendered frame in the chassis, one
  Send to reader, opt-in session Auto-send, 1s local autosave, no content
  confirmation dialogs; ContentSendStatus (pure, 9 tests) gates Send and only
  reports "Shown on reader" for the redraw receipt of the canvas revision.
  Settings button is "Save reading settings", theme button "Send theme".
  iPad/iPhone keep the sheet until U4. User then ran the new Mac build on X3:
  edit -> Send to reader reached "Shown on reader" and the e-ink screen updated.
  Direction change the same day: U2 inline card editing stopped in favour of a
  Pocket Daily profile (home sections/order, feature on/off, then sleep screen)
  via P0 inventory -> P1 firmware/host renderer -> P2 studio. See NEXT_STEPS.md.

- 2026-09-24 physical follow-up: cleanup firmware wbcb431b1 installed once
  wirelessly and automatically returned to dedicated Pocket Daily Sync STA.
  Latest Mac app connected without a reader re-entry or Mac network change.
  Actual app Apply of the existing card returned rendered/none at generation1
  (admission heap16,448B/block10,740B). Editing its text and applying in the
  same session activated generation2 but returned failed/memory at14,184B/
  7,156B. Restoring the original through the app activated generation3, also
  failed/memory at13,140B/8,180B. Original local draft was never overwritten.
  Identity-bound state/receipt reads verified the restoration; connection
  remained responsive. These are driver receipts, not new optical confirmation.
  Repeated Apply acceptance remains blocked by firmware admission memory;
  transfer/activation and display must not be conflated. No blind retry,
  additional flash, guard reduction, AP or X4 acceptance. Installation evidence
  is sibling build/product-cleanup-install-20260924.log.

- 2026-09-24 scope audit recorded in PRODUCT_SCOPE_REVIEW.md. Sibling removes
  games/routing/translations and per-paint home menu vectors; no SD user data
  touched. Default-off AgentDeck retained due to shared cached-card/cover state;
  base reader and optional offline content preserved. Companion now tolerates
  transient GET transport errors only after an acknowledged queued paint,
  pacing reads at2s with45-read/90s monotonic admission budget. An already
  started HTTP read retains15s request timeout. Never repeats POST/upload/
  activation or changes network; cancellation, bad identity/generation and
  explicit failed receipt remain terminal. This is confirmation resilience,
  not reduced firmware font-preparation time. Firmware wbcb431b1 was subsequently
  installed; physical results and remaining failure are recorded above.
  Final validation: all267 Swift tests pass, including queued timeout/recovery,
  monotonic deadline, read-count bound, cancellation and same-session model
  integration. Existing integration wait adjusted for the intentional2s poll
  instead of changing production pacing to suit tests. iOS test build and Mac
  build pass; App Store source validation and both diff checks pass. Logs:
  .build/product-cleanup-tests-final.log, product-cleanup-mac.log. Sibling359
  host tests/default build/strict check pass; seven removed tests were games.

- 2026-09-24 user optically confirmed the preserved card is displayed on X3
  we46ca975 after the successful rendered receipt. This completes that single
  shared-LAN card's visual check, not repeated edits or private-AP acceptance.
  Product connection wording now separates Same Wi-Fi and Direct connection;
  app retains old-label compatibility and direct Wi-Fi-switch confirmation.
  No screen-preview failure should tell users to reconnect to Nearby Sync.
  Sibling UI guides app use instead of browser URLs in dedicated Sync only;
  File Transfer remains the browser fallback. See SYNC_SESSIONS.md. New UI
  code is not installed on the reader; active hardware session is untouched.
  Verification: 263 Swift tests, iOS/Mac builds, sibling366 host tests/default
  build/strict cppcheck pass. iPhone11 UI tests and Mac screenshot test pass;
  iPad iOS27 run passes10/11 including connection guidance but fails the
  existing editor keyboard/layout-selector test (also fails isolated). On
  iPad iOS26.5 both editor and connection-guidance tests pass. Do not describe
  the iOS27 failure as fixed. All three screenshot sets regenerated/exported,
  connection layouts inspected, App Store source validation passes. Evidence
  is .build/connection-ux-*. Firmware UI artifact w024683da remains staged only.

- 2026-09-24 we46ca975 dedicated Sync returned rendered/none for the preserved
  generation1 after one display-only request, without content retransmission.
  Admission heap17,996B/block12,788B now passes the unchanged guard; previous
  build failed at14,212B/9,204B. Early receipt/status reads timed out during
  preparation before a later receipt succeeded. User optical confirmation
  and repeated app Apply remain pending; do not claim delay-free sync, AP or
  X4 acceptance from this single hardware result.

- 2026-09-24 user-authorized we46ca975 sibling firmware installation verified
  on the same X3 after a single uninterrupted wireless transfer and dev flash.
  Existing active card/generation1 preserved; no Mac network changes or content
  retransmission. Legacy initiating firmware returned to File Transfer STA;
  one dedicated Pocket Daily Sync entry requested before physical route-heap
  and redraw verification. Installation is complete, not display acceptance.

- 2026-09-24 sibling firmware removes persistent per-endpoint HTTP route
  allocations in dedicated Sync using exact request-scoped dispatch and one
  shared route definition. Browser File Transfer and multipart upload retain
  registered handlers; wire contracts and 16KiB/4KiB display floors unchanged.
  Sibling 366 host tests, default build and strict cppcheck pass; companion's
  26 focused preparation/presentation/transport tests pass with no Swift edits.
  Staged we46ca975 includes the earlier boot-return fix, but is not installed.
  Heap savings and same-session redraw still require physical verification;
  next test should present the existing active card, not re-upload content.

- 2026-09-24 physical dedicated Sync test on installed waefed08b: poll-only
  profile and unchanged active generation1 confirmed. One display-only POST
  returned queued; GET returned failed/memory with deferred admission sample
  heap14,212B and largest block9,204B. Total free heap, not the4KiB block floor,
  failed the unchanged16,384B guard (short2,172B). Thus deferring HTTP cleanup
  alone is insufficient on this X3; no font preparation/display was admitted.
  No content transfer, activation, firmware install or assistant network change.
  Keep the session; do not repeat uploads/rejoins or lower the guard merely
  to force a paint. Persistent resource budgeting remains unresolved.

- 2026-09-24 sibling now records developer-update origin and restores shared
  LAN Sync versus File Transfer instead of always choosing File Transfer.
  Nearby/AP returns to the correct chooser for a new authenticated lease;
  saved-STA association is attempted only once and falls back to existing UI.
  Legacy initiating firmware lacks origin metadata, so its first upgrade still
  returns to File Transfer. No Swift/HTTP request changes or new installation
  in this turn. Sibling364 host tests/default build/strict checks pass; new
  we5626481 artifact is staged only. See SYNC_SESSIONS.md and sibling
  docs/dev-update-return.md. Device redraw remains unverified.

- 2026-09-24 user-authorized waefed08b installation verified on the same X3.
  First stream timed out after1MiB logged ACK; HTTP/TCP/ICMP briefly stopped
  responding, then HTTP recovered without reboot or user network changes.
  One controlled continuation required nonzero RESUME (1,081,344B), completed
  size6,107,488/CRC954C70A6, published, flashed once and verified exact version
  1.6.6-dev-main-b8e38e39-waefed08b. Active card generation1 survived unchanged.
  Boot returned to File Transfer STA/push, so deferred Sync presentation is
  not yet tested; requested one entry into Pocket Daily → Sync → Join a Network.
  No content retransmission. Sibling build/deferred-install*-20260924.log holds
  private evidence. Do not equate installation with redraw/connectivity success.

- 2026-09-24 sibling defers content/font preparation until HTTP request cleanup
  and upload reply-grace release, serializing subsequent request allocations
  against painting without a radio change. Same16KiB/4KiB admission floors;
  optional schema1 failure/heap/block describe deferred rejection and its
  sampled budget. Swift accepts legacy receipts and reports memory/preparation
  separately, with generic fallback for unknown reasons and no resend. All263
  app unit tests and Mac build pass (.build/deferred-presentation-* logs).
  Full iPhone/iPad UI tests, Mac captures and source-package validation pass
  (.build/deferred-presentation-ui.log); regenerated profile images inspected.
  Firmware362 host tests/default build/strict check pass; frozen waefed08b
  artifact is recorded in sibling memory. No device install or mutation in
  this follow-up; redraw and AP/X4 acceptance remain pending. See
  SYNC_SESSIONS.md and sibling docs/content-display.md for lifetime contract.

- 2026-09-24 presentation error recovery now preserves the original POST
  rejection if its read-only recovery query fails; cancellation propagates
  without another mutation. Successful read recovery still handles a lost
  response. All262 app unit tests and Mac build pass (presentation-error-*
  logs in .build). No layout or firmware binary changes in this follow-up.
  Same-session physical status remained responsive and free heap recovered
  partially to14,212B; one display-only retry after idle still returned503
  low memory. No upload, activation, rejoin or flash. Source audit confirms
  view/font preparation occurs inside the HTTP callback, before SDK client
  cleanup; moving it out is a candidate, not a verified root fix. See
  SYNC_SESSIONS.md for the pending resource-lifetime investigation. Device
  redraw and private-AP/X4 acceptance remain incomplete.

- 2026-09-24 first dedicated COMPANION physical Apply on installed w615b26dd
  succeeded through durable activation (generation1), but not presentation.
  Status confirmed poll-only/diagnostics off and app preferences loaded. One
  saved Korean card Apply reported storage confirmed; GET state independently
  confirmed active revision. A single display-only POST (no upload/activation)
  returned HTTP503: Reader memory is too low for content presentation. Status
  afterward reported11,856B free; firmware admission requires16,384B and4KiB
  largest block. The app's fallback GET obscures the original503 with a409
  not-being-presented message. Preserve that primary failure in future work.
  No new firmware installation, radio change or content resend. This is one
  successful dedicated transfer, not idle/repeated-apply/direct-AP acceptance.

- 2026-09-24 user-authorized resumed wireless installation succeeded. Reader
  retained2,048,000 bytes; verified remaining transfer/publication followed by
  one dev flash and exact `1.6.6-dev-main-b8e38e39-w615b26dd` on the same
  identity. Sibling build/sync-install-resume-20260924.log holds evidence.
  Mac Wi-Fi unchanged. Reader auto-returns to File Transfer STA, which still
  advertises push/diagnostics; user must select Pocket Daily → Sync → Join a
  Network to exercise the dedicated profile. No content Apply in this turn.
  This supersedes the installation blocker below, not the pending physical
  card/redraw, private-AP, idle or X4 acceptance gates.

- 2026-09-24 the separately approved one-attempt wireless installation of the
  new Sync firmware failed during bulk copy, before publication/flash. Old
  firmware still answered status afterward; new dedicated-profile behavior is
  therefore not installed or physically tested. No automatic resend or network
  switch. Sibling build/sync-install-20260924.log holds private transfer evidence.
  One-time SD bootstrap is the next proposed path, not an already performed step.

- 2026-09-24 Pocket Sync is now the app's primary guidance for both shared
  Wi-Fi and explicit BLE/private-AP connection; File Transfer remains fallback.
  A failed pre-lease BLE attempt releases the pending direct flag without Wi-Fi
  changes, allowing LAN or another explicit direct attempt. Acquired leases and
  active association remain protected from late BLE failures. Immediate repeated
  permission/radio failures are handled even when SwiftUI sees no state change.
  Preview/heartbeat guidance no longer asks users to switch connection methods.
  The sibling now keeps both dedicated profiles poll-only and fixes private-AP
  theme endpoints missing despite advertised support; no wire grammar changed.
  See SYNC_SESSIONS.md. All260 app tests and Mac build pass
  (.build/sync-session-regression-complete.log, .build/sync-session-mac-final.log).
  Full iPhone/iPad UI, Mac screenshots and source-package validator pass
  (.build/sync-session-ui.log); regenerated iPhone/Mac images inspected. Updated
  Mac app opened offline with its saved Korean draft intact. Firmware358 host
  tests/default build/strict check pass. No device transfer, Wi-Fi switch or
  firmware installation in this change; physical stability, no-router pairing,
  repeat card redraw and X4 acceptance remain pending. One-time wireless install
  approval requested separately; do not infer it from a successful build.

- 2026-09-24 physical retry on the unchanged installed `w6fafa273`: the Mac
  app connected in POLL mode with the current-memory guard, then one explicit
  saved text-card Apply reached the asset phase and timed out before activation.
  Thus manifest preparation returned, but the asset sub-operation that failed
  is not yet isolated. A later state read returned `active:null` and ping
  responded; an intervening HTTP connection had timed out. The SD-independent
  transfer-stats response then returned only its first JSON section: attempt1,
  Complete,124 expected/received/accepted bytes,1079ms. Its remainder timed out.
  No complete stats receipt, redraw, repeated Apply or firmware installation.
  A subsequent HTTP/1.0 comparison could not connect, so it is not a framing
  A/B result. Client WebSocket suppression alone does not fix this failure;
  firmware listener allocation and the network path remain unisolated. Earlier
  uptime drops were explained by the user's File Transfer exit/re-entry, not
  evidence of spontaneous resets. Avoid another blind upload/rejoin loop.

- 2026-09-23 added current-memory admission to app push selection: advertised
  WS alone no longer opens a second socket/frame subscription below16 KiB,
  the sibling's existing listener-admission floor. Reader observations showed
  push advertised with roughly10–12 KiB free after listener allocation. The
  existing paced HTTP path stays available. This is a resource guard, not yet
  a verified cause/fix for hardware failure. A read-only, SD-independent
  transfer-stats response also stopped after its first JSON chunk, so the
  partial file-list response does not isolate SD as the cause. Device uptime
  decreased between observations; the user subsequently confirmed exiting and
  re-entering File Transfer, so these were not one continuous failure.
  All256 app tests and Mac build pass (`.build/push-admission-regression.log`,
  `.build/push-admission-mac.log`); updated Mac app relaunched without opening
  a reader connection. Initial new fixture tried to mutate an immutable status
  field; corrected to construct each status before the successful full run.
  No firmware modification/installation or hardware success claim.

- 2026-09-23 physical content acceptance remains blocked: after the user's
  reboot, status and Mac LAN connection succeeded on `w6fafa273`, but the first
  card Apply timed out at the initial state check and a separate HTTP status
  probe could not connect. No content activation/redraw was confirmed. The
  saved crash shown by the app identifies an older firmware, not this failure.
  The test draft was saved locally. Do not repeat firmware installation as a
  remedy or claim idle stability. App Apply now revokes stale connected state
  immediately for initial-check reachability errors, before uploads, instead
  of waiting for later heartbeat failures; cancellation/response errors and
  post-staging failures retain their existing recovery semantics. No automatic
  reconnect, network change or resend was added.27 related tests, all255 app
  tests and Mac build pass (`.build/content-offline-tests.log`,
  `.build/content-offline-regression.log`, `.build/content-offline-mac.log`).
  Updated Mac app was relaunched offline; the saved Korean draft is preserved.
  Full iPhone/iPad UI, Mac screenshot and source-package validation pipeline
  also passes (`.build/content-offline-ui.log`); regenerated iPhone inspector
  and Mac profile images inspected. This does not establish reader stability.

- 2026-09-23 user explicitly authorized physical X3 installation after reporting
  File Transfer readiness. Sibling one-attempt wireless dev update verified
  `1.6.6-dev-main-b8e38e39-w6fafa273`; content state now returns schema1/caps7
  with no active revision and status advertises contentPresentation=true.
  The existing built Mac app was reopened and Find & Connect selected that X3
  over the unchanged LAN; its visible device header reports the exact new
  version and STA. No cards/settings were applied. Physical content/redraw and
  long-idle acceptance remain pending; installation is no longer the blocker
  for testing the new content path. Detailed transfer evidence is in the
  sibling build/device-install-20260923.log and its project memory.

- 2026-09-23 content reference preview now labels previous and next separately,
  matching sibling ContentPresentation's localized mapped controls. Actual
  bundled-font preview pixels match direct rendering with Back/empty/Prev/Next;
  the resulting image was inspected.10 rendering/preview tests and Mac build
  pass (`.build/content-hints-tests.log`, `.build/content-hints-mac.log`), plus
  sibling356 host tests/default build/strict cppcheck. No shared renderer/ABI
  change or host artifact reimport; no physical reader contact. Full iPhone/iPad
  UI suites, Mac screenshot capture and source-package validator pass in one
  pipeline (`.build/content-hints-ui.log`); store images regenerated. Corrected
  iPhone editor capture inspected at `.build/content-hints-editor-iphone.png`.

- 2026-09-22 content editor now offers explicit session-scoped live apply.
  ContentLiveApply coalesces valid edits after800ms, keeps only the latest edit
  during Apply, clears queued content on invalid edits and stops on uncertainty.
  PocketModel reuses the existing Apply task and requires matching connection
  generation, identity, activation and redraw receipts. Cancellation targets
  that task; no new transport/reconnect/firmware path exists. Editor closure,
  background/session change and draft import/recovery revoke authorization;
  Save remains local and demo cannot enable it. Four coordinator tests and the
  actual Apply integration cover coalescing, queued edits, invalidation, failure,
  late completion, successful redraw and stale-session refusal. All254 app
  tests and Mac build pass (`.build/live-apply-tests.log`,
  `.build/live-apply-mac.log`). iPhone11 UI tests pass; iPad initially passed
  10/11 with the import test executing an older readiness wait than the current
  source. A separate derived-data build passes both import and demo/live-button
  tests (`.build/live-apply-ipad-retest.log`), including the new button assertions.
  The original failed pipeline log remains `.build/live-apply-ui.log`; do not
  describe it as a green full run. Mac capture and source-package validation
  pass; all platform store images were regenerated and both editor captures
  inspected. Final confirmation also pins the session when the dialog opens,
  refusing a changed session at confirmation;11 focused tests and Mac rebuild
  pass (`.build/live-apply-final-focused.log`, `.build/live-apply-mac-final.log`).
  No physical reader contact or hardware sign-off. See CONTENT_EDITOR.md.

- 2026-09-22 manual verification and direct association now share the app's
  token-owned work lane. Separate verification/join handles, association owner
  and early busy-state cleanup are removed. Explicit connection replacement
  cancels and waits for predecessor I/O/cleanup; only the latest queued owner
  runs. A cancelled successful OS join leaves its SSID before the next join,
  including same-SSID replacement. Backgrounding keeps busy until drain;
  foreground alone never joins. Verification launch helpers reserve admission
  synchronously. Controlled tests hold association and leave separately, verify
  three-request replacement skips the middle join, and retain HTTP cancellation
  coverage. All250 app tests and Mac build pass
  (`.build/connection-owner-final.log`, `.build/connection-owner-mac.log`). No
  physical device/network association, firmware/wire or UI-layout change. App
  operation ownership is consolidated; full DeviceSession/view decomposition,
  physical OS/radio and long-idle acceptance remain open.

- 2026-09-22 LAN discovery now uses the common token-owned reader-work lane;
  its separate task/busy cleanup is removed. Admission is synchronous, duplicate
  searches are refused, and both bounded passes plus retry delay share one owner.
  Cancellation drains Bonjour before release; a late endpoint cannot start a
  new status probe. A held non-cooperative discovery test verifies background/
  foreground, blocked replacement verification/file admission/session end, no
  late message or HTTP, then successful new search.88 related tests initially
  pass (`.build/discovery-lane-regression.log`); after adding the late-endpoint
  guard,87 pass (`.build/discovery-lane-final.log`), excluding only the unchanged
  six-MiB loopback test already passed in the preceding run. Final Mac build
  passes (`.build/discovery-lane-mac-final.log`). No reader/network association,
  upload, wire change or UI-layout change. Manual verification/private joins
  remain separate tasks; this is not full DeviceSession or hardware sign-off.

- 2026-09-22 same-session Apply integration now covers failed redraw, stale
  generation, lost POST+GET responses, explicit same-content retry, lost POST
  resolved by GET alone, and the next changed draft. The existing coordinator
  already skips staging/activation for a verified active revision; no second
  retry implementation was needed. Tests assert unchanged manifest/asset upload
  counts, activation generation and selected reader during redraw recovery.
  All248 app tests pass (`.build/session-final-regression.log`). Initial fixture
  incorrectly expected a bad POST followed by a valid GET to fail; the corrected
  fixture distinguishes successful read recovery from two invalid replies.
  HTTP/storage are injected: this is not physical reader acceptance.

- 2026-09-22 offline preparation, SD copying, activation-journal local recovery
  and explicit session end now use the existing token-owned app-work lane.
  Local work reserves admission before scheduling, rejects demo/background
  writes, drains cancellation and retains completed file receipts; it does not
  interrupt/restart reader monitoring.18 focused tests and Mac build pass
  (`.build/local-work-focused-final.log`, `.build/local-work-mac.log`), followed
  by the248-test full regression above. Connection establishment and full
  DeviceSession migration remain open. No physical SD, device or network action.

- 2026-09-22 sibling duplicate-staging reclamation now resumes partial removal
  on a later explicit seal: same verified published manifest plus exact verified
  remaining-file inventory, without recreating deleted assets. Corrupt/extra
  data or missing manifests remain preserved. Internal inspection counters do
  not change HTTP receipts;32 companion contract tests pass
  (`.build/staging-cleanup-resume-contract.log`) alongside355 firmware host tests,
  default build and strict cppcheck. No app source/UI change, reader contact or
  upload. This is bounded duplicate cleanup, not total storage admission.

- 2026-09-22 sibling idempotent content seal now removes a fully verified
  duplicate staging copy when the published revision is also verified. Unknown,
  incomplete/corrupt staging is preserved; cleanup failure never converts a
  valid published revision into a resend request. Manifest-listed deletion only,
  unchanged SealResult/HTTP/Swift contract.354 firmware host tests/default build/
  strict cppcheck pass;32 companion deployment/adapter/HTTP tests pass
  (`.build/staging-duplicate-contract.log`). No Swift source/UI change or reader
  contact/upload. General orphan cleanup and capacity admission remain open.
  The accepted host renderer artifact is unchanged; this storage-only change
  does not claim a rebuilt renderer source snapshot. See CONTENT_DEPLOYMENT.md.

- 2026-09-22 settings Save and explicit preview fetch now join the same
  token-owned reader-work lane as the five transfer paths. The separate
  readerOperationTask/background-clear path is removed; all seven paths drain
  cancellation before release. Work kind preserves settings/preview semantics
  (no file-transfer controls). Discovery, verification, lease replacement and
  explicit session end refuse admission while any reader work owns I/O. Eight
  focused tests pass (`.build/reader-work-focused.log`), including held real
  URLSession requests intercepted locally, settings edits during save, early
  background cancellation and existing repeated content Apply. The older test
  that simulated a new owner by assigning isWorking directly now exercises
  actual foreground/re-entry admission instead: no second owner is allowed
  before drain. No firmware/wire/UI layout change or physical reader/network
  association. Mac build passes (`.build/reader-work-mac.log`). Full regression
  passed244/246 tests; two older cancellation tests expected a new settings
  write while still backgrounded. They now assert no background write, completed
  cancellation, then successful foreground replacement. Both and two related
  cancellation tests pass (`.build/reader-work-cancellation-retest.log`). The
  original non-green full-run log is retained as `.build/reader-work-regression.log`;
  no claim is made of a second full-suite run. Offline preparation, connection
  establishment and the full DeviceSession migration remain unfinished.

- 2026-09-22 app file/content/theme transfers now share one token-owned
  start/drain/finish boundary. Manual verification and discovery cannot replace
  the session until cancelled I/O returns; late notes/progress/private-link
  recovery require the owning operation and connection generation. A controlled
  test reproduced verification clearing busy/reader state during cancelled Apply
  before the fix (`.build/transfer-lane-before.log`). Explicit cancellation and
  background/foreground cases now pass, including the next Apply;22 initial
  focused tests and the macOS build pass (`.build/transfer-lane-focused.log`,
  `.build/transfer-lane-mac.log`). No physical reader/network association,
  firmware change, upload or new UI. Full245 app tests also pass in
  `.build/transfer-lane-regression.log`. Offline preparation and the full
  session-owner migration remain separate; see CONTENT_DEPLOYMENT.md.

- 2026-09-22 the actual PocketModel Apply lifecycle now has an injectable
  revision/session-bound transport factory (production still constructs the
  existing ReaderContentTransport). A local integration test runs first Apply,
  failed changed-card upload, then successful Apply in the same model. It checks
  unchanged selected reader, previous active revision on failure, image reuse,
  journal clearance and two identity/revision/generation-validated redraw HTTP
  responses. Storage I/O and HTTP are simulated; no physical reader is contacted.
  This exposed a UI status mismatch: successful redraws were always labeled
  screen-unconfirmed. The model now retains the exact redraw receipt, clears it
  for a new Apply, and the editor distinguishes confirmed redraw from storage
  activation. All244 app unit tests and the macOS build pass
  (`.build/content-session-regression.log`, `.build/content-session-mac.log`);
  iPhone11 UI tests pass. iPad initially passed10/11: the import test waited for
  a lazily-created off-screen button after reopening a saved card. Its readiness
  check now accepts the visible first card or import button; the isolated iPad
  retest passes (`.build/content-session-ipad-import.log`). Mac screen tests and
  source-package validation pass; all platform screenshots were regenerated and
  representative images inspected. The full screenshot script's initial exit65
  is retained in `.build/content-session-ui.log`, not reported as a green run.
  Mac capture resumed separately (`.build/content-session-mac-ui.log`).
  IMPLEMENTATION_PLAN.md now gives the integration path priority over peripheral
  expansion and explicitly supersedes conflicting historical phase gates.

- 2026-09-22 card-detail layout is connected end-to-end locally: Swift picker,
  saved/reloaded draft, PDCT v2 bytes, manifest capability4, immutable deployment,
  firmware seal/activation/load and shared native/host rendering. Text first
  retains byte-exact v1; image first and side-by-side require capability before
  staging. Nondefault drafts use schema2 so old apps refuse rather than discard
  layout.236 app tests/macOS build,350 firmware host tests/default build/strict
  cppcheck pass (`.build/card-layout-app-tests.log`, `.build/card-layout-mac.log`,
  sibling `build/card-layout-{host-final,firmware,check}.log`).48 real-font mode
  frames/40 C-ABI frames match; accepted artifact is `apple-host-0pvcfof1`.
  HAL/heap constraints added no frame buffer or render-time allocation. No
  reader contact/upload. This completes a local card-detail feature, not the
  multi-surface studio or physical acceptance; see CONTENT_EDITOR.md and sibling
  content-card-layout-v2.md. iPhone/iPad UI suites (including layout selection),
  Mac screen capture and source validator pass (`.build/card-layout-ui.log`).
  The real bundled-font layout test also passes; its three rendered images and
  iPhone editor screenshot were visually inspected (`.build/card-layout-reference.xcresult`).

- 2026-09-22 the prior localhost flow-test failure overlapped verified Mac
  sleep (18:29:34–18:45:18 and18:45:20–19:00:28); it cannot establish a physical
  reader defect. The unchanged isolated test passes in129.316 seconds
  (`.build/content-flow-isolated.log`). Its failure report now includes bounded
  last-confirmed-offset and elapsed/idle durations; production pacing/timeouts,
  payload and assertions are unchanged. Full233 app tests pass in172.461 seconds
  (`.build/content-flow-regression.log`). Power/network settings were not changed;
  no reader contact/upload. See TRANSPORT_RELIABILITY.md for timestamp evidence.

- 2026-09-22 content deployment refuses repeated Apply while its original
  activation outcome is pending, before resetting state or making transport
  calls. The original snapshot remains confirmable, with or without a disk
  journal. A regression reproduced lost pending state before the fix.37 related
  tests now pass (`.build/content-pending-reentry-tests.log`), including saved
  draft/reload, immutable deployment, lost activation response and failed redraw
  integration through injected reader I/O; macOS build passes
  (`.build/content-pending-reentry-mac.log`). No firmware/protocol/UI change,
  reader contact, upload or network switching. Local tests are not physical
  acceptance evidence; full product completion remains open.
  Full regression (`.build/content-pending-reentry-regression.log`) subsequently
  ran233 tests:232 passed; existing localhost six-MiB flow-control test failed
  with `stalled` after1887.852 seconds. Cause remains undetermined; this is not
  a green full-suite result or evidence about the physical reader.

- 2026-09-22 sibling content seal now rejects undeclared files/subdirectories
  or incomplete directory accounting before publication, on idempotent reuse
  and after move. Existing activation errors/receipts are unchanged. The Swift
  adapter's manifest+declared-assets layout remains compatible;25 revision/
  deployment/adapter tests pass (`.build/content-inventory-contract.log`), with
  sibling348 host tests/default build/strict cppcheck passing. No Swift source
  change, reader contact/upload or physical-media claim. This is seal validation,
  not pre-upload capacity reservation or automatic leftover cleanup. See
  CONTENT_DEPLOYMENT.md and sibling docs/content-storage-admission.md.
- 2026-09-22 manual direct-lease verification now owns the tracked verification
  task and drains optional reader traffic before its HTTP wait. Background,
  caller cancellation and a replacement join cancel it; stale completion and
  timeout fallback cannot release or overwrite a newer attempt. Four focused
  verification tests pass (`.build/manual-verification-tests.log`), including
  two new controlled URLProtocol/association cases; iOS test build and macOS
  build pass (`.build/manual-verification-mac.log`). No network association or
  physical reader calls. Full session-owner consolidation remains unfinished.

- 2026-09-22 direct association I/O is injectable. Join completion/defer now
  checks attempt ownership; stale cleanup cannot disconnect a newer same-SSID
  owner. Backgrounding drops join ownership/busy state and refuses queued
  leases; foreground alone does not reacquire ownership. Two controlled tests
  cover same/different-SSID replacement, late cleanup after background/foreground
  and no implicit join (`.build/join-ownership-tests-final.log`). iOS test build
  and macOS build pass (`.build/join-ownership-mac-final.log`). No actual Wi-Fi
  or reader calls. OS calls already in flight remain non-interruptible; manual
  verification and complete session-owner consolidation remain separate work.
  The subsequent full229 app unit tests pass
  (`.build/join-ownership-regression.log`), before the manual-verification follow-up.

- 2026-09-22 explicit Mac direct-join work now forwards caller cancellation
  into its detached CoreWLAN worker and checks after authorization/scan before
  starting further work. Cancelled callers reject late success receipts.
  An already-running synchronous OS association remains non-interruptible;
  this does not guarantee network restoration.16 core tests pass, including
  cooperative worker cancellation, non-cooperative late completion, normal
  success and pre-cancelled admission (`.build/connection-worker-tests.log`).
  macOS build passes (`.build/connection-worker-mac.log`). These tests never
  call CoreWLAN or join a network; LAN behavior and firmware are unchanged.

- 2026-09-22 LAN discovery's800ms single-retry delay now belongs to the tracked
  discovery task instead of an untracked timer. Busy remains true across the
  delay, duplicate Find actions are refused, and background cancellation stops
  the second pass. Attempt guards preserve newer ownership. The existing
  NearbySyncProtocol suite plus the new delay/cancellation regression pass
  (`.build/discovery-retry-owner-tests.log`), as does the macOS build. Tests use
  controlled discovery/URLProtocol/loopback servers; no physical reader contact
  or firmware upload. Probe timings and the one-retry limit are unchanged.
  This is local session-lifetime progress, not measured radio reliability.
  The iPhone/iPad UI suites, Mac screenshot capture and source-package validator
  subsequently pass (`.build/discovery-retry-owner-ui.log`); representative
  regenerated iPhone/Mac images were inspected.

- 2026-09-22 theme drafts now support portable schema1 JSON import/export of
  the existing eight metrics, separate from private generation/epoch records
  and binary UI packs. Imports are bounded to16KiB, validate exact fields and
  bounds, and stage an explicit current/imported comparison. Confirmation edits
  memory only; Save and reader Apply remain separate. Export takes an immutable
  snapshot. Demo refuses both, and cancellation/late edits invalidate imports.
  Full223 app unit tests pass (`.build/theme-files-regression.log`); the focused
  simulator recovery/import flow passes (`.build/theme-files-ui.xcresult`),
  including cancel, unsaved relaunch and explicit save/relaunch. Its comparison
  screenshot was visually inspected. Both unsigned iPhoneOS/macOS Release builds
  pass and exclude DEBUG fixture markers. The additional unchanged-value reload
  race and all7 portable-file tests pass (`.build/theme-files-reload-tests.log`).
  The full iPhone/iPad UI and Mac screenshot pipeline and source-package validator
  pass (`.build/theme-files-screenshots.log`); representative platform images
  were inspected. The native provider picker and actual
  export destination selection remain unverified by that fixture-driven UI test.
  No reader contact, firmware changes or upload. Named/resource packs and theme
  host rendering remain unfinished; see THEME_DRAFT.md.

- 2026-09-22 sibling staging ingress now caps individual files at256KiB across
  stream, HTTP, legacy WS, WebDAV and relocation/commit paths; resumed prefixes
  count toward the bound. Existing Swift manifest/assets fit the ceiling, so
  no app code or receipt schema changed.15 manifest/revision/adapter tests pass
  (`.build/content-ingress-contract.log`); sibling332 host tests/default build/
  strict cppcheck pass. This does not report free space or impose aggregate
  storage quotas, and no reader was contacted/uploaded. See CONTENT_DEPLOYMENT.md
  and sibling docs/content-storage-admission.md for remaining capacity work.

- 2026-09-22 sibling activation now attempts best-effort retirement of the one
  evicted content revision after verified selection. Both recovery records and
  any non-idle presentation are pinned; uncertain metadata prevents deletion,
  only manifest-listed files are removed and unknown descendants survive.
  Cleanup failure does not change the schema1 activation receipt or trigger app
  retries.330 firmware host tests/default build/strict local-tool cppcheck pass;
  companion28 deployment/transport/receipt/presentation tests pass
  (`.build/content-retirement-contract.log`). No Swift or wire-format change,
  device contact/upload or physical deletion. Quota/admission, durable cleanup
  retry and orphan/staging collection remain unfinished. The existing host
  renderer artifact still verifies; it retains its earlier provenance snapshot
  rather than claiming the current firmware storage source. See
  CONTENT_DEPLOYMENT.md and sibling docs/content-retention.md.

- 2026-09-22 theme-draft recovery now requires explicit confirmation, preserves
  the original regular file byte-for-byte before atomic replacement, and exposes
  its backup for user-initiated export. Recovered records use schema2 with a UUID
  epoch so stale pre-recovery editors cannot overwrite them even when generation
  numbers coincide; subsequent saves preserve the epoch. Demo has no storage
  dependency. Recovery retains later typing and completed write receipts even
  after caller cancellation. Full216 app unit tests pass
  (`.build/theme-recovery-regression.log`); the added cancellation/concurrency
  case and all11 theme tests pass (`.build/theme-recovery-races.log`). The complete
  iPhone/iPad UI and Mac screenshot pipeline plus source-package validation pass
  (`.build/theme-recovery-screenshots.log`); representative images were inspected.
  UI tests cancel recovery, confirm it, save an edit and verify it after relaunch.
  The isolated corrupt-file fixture is DEBUG-only; both unsigned iPhoneOS and
  macOS Release builds pass and exclude its markers. No reader contact or upload.
  Backup browsing/comparison, portable editable documents, named packs and
  theme-pack host rendering remain open; see THEME_DRAFT.md.

- 2026-09-22 theme metrics now have a typed local `ThemeDraft`, actor-owned
  schema1/generation store and shared `ThemeEditorModel`. Save is explicit and
  separate from Apply; app windows share one editor, demo has no storage
  dependency, and mode changes do not mix drafts. Reads are bounded to16KiB;
  unknown/corrupt/invalid records are never silently replaced. Stale saves and
  generation overflow fail; typing during load/save is preserved. The existing
  eight fields encode unchanged PDUI records.213 app unit tests pass, including
  seven draft tests (`.build/theme-draft-regression.log`). iPhone/iPad UI suites,
  macOS capture/build and source-package validation pass
  (`.build/theme-draft-screenshots.log`); generated screens were inspected. The
  compact-iPhone follow-up passes after directly querying the Stepper button's
  actual identifier (`.build/theme-draft-ui-final-v2.xcresult`). Demo UI verifies
  Save/Apply/Revert remain disabled. Reader Revert remains
  independent of local draft loading. Backup recovery, named documents,
  import/export and theme-pack host rendering remain open; see THEME_DRAFT.md.
  No reader requests, firmware changes or uploads were made.

- 2026-09-22 offline content preview + disconnected theme editing now pass the
  complete screenshot pipeline with explicit iOS26.5 iPhone17ProMax/iPad13M5
  UDIDs, plus macOS offscreen captures and the App Store source validator
  (`.build/offline-studio-screenshots-final.log`, exit0). Updated platform images
  were visually inspected. iPhone summary records9/9 UI tests; both new editor
  flows are included. This closes the earlier iPad lazy-row regression checks,
  not physical reader acceptance. The earlier automatically selected iOS27
  iPad run finished8/9; its hierarchy proves the theme test still used the old
  parent accessibility identifier that overwrote child identifiers. The fix
  removes that parent identifier. Both editor tests subsequently pass on iOS27
  with the current code (`.build/offline-editors-ipad27-final.xcresult`,2/2).
  This focused rerun is separate from the complete pinned26.5 baseline; the
  earlier failure was not evidence of a reader/network failure.
  Screenshot overrides accept exact UDIDs and an isolated derived-data folder;
  failures preserve diagnostics rather than erasing evidence. No device access,
  firmware upload, release submission, commit or push occurred.

- 2026-09-22 the existing theme-metric inspector now supports local editing
  without a connection; only Apply/Revert are gated by capability, identity,
  idle state and non-demo mode. Draft values are labeled temporary and distinct
  from connected-reader settings; persistent pack documents remain unfinished.
  The dedicated iPhone UI test edits Header44→45 and proves both device actions
  remain disabled (`.build/offline-theme-ui-v2.xcresult`); macOS build passes
  (`.build/offline-theme-mac.log`). The14 relevant preview/pack unit tests pass
  (`.build/offline-theme-unit.log`). No protocol or firmware changes/device access.
  Full screenshot regression subsequently passed on the pinned baseline above.

- 2026-09-22 content editor now uses the shared renderer for offline card/empty
  previews, with four orientations and a pinned PocketSansWorld 12 px font plus
  source/OFL notices in Support/PreviewFont. Reference Base/English settings are
  labeled explicitly; this is not a connected-reader capture or settings match.
  Debounce/generation guards reject cancelled and superseded results; font and
  drawing work stay off the main actor. Full206 app unit tests pass, including
  actual bundled-font Korean rendering (`.build/content-preview-regression.log`).
  The dedicated iPhone editor UI test passes and its captured page was visually
  inspected (`.build/content-preview-ui-v3.xcresult`); the test now requires a
  visible preview, not merely an offscreen accessibility element. Scrolling the
  iOS form dismisses the keyboard. Final macOS build passes
  (`.build/content-preview-mac-final.log`). No device contact/upload.
  iPad capture also shows the rendered card; its flow test exposed a lazy Form
  assertion reading Apply before that row existed. The test now scrolls until
  both Save and Apply exist. The pinned screenshot suite subsequently passes
  this correction; capture failures now retain result bundles for diagnosis.
  User's no-reconnect/no-upload-loop boundary remains active; hardware acceptance,
  other native surfaces and UI-pack rendering are still open.

- 2026-09-22 imported the verified host XCFramework (no device image/source/font)
  into Support/PocketUIHost. Import pins source/artifact hashes, preserves old
  artifacts in ignored backups and rejects changed files. Both Xcode targets
  link it through project.yml and run a sandboxed integrity check with explicit
  xcfilelist inputs; metadata is bundled for runtime ABI/pin agreement without
  a sibling checkout. HostRendererBridge actor now renders PDCT/PBM/empty pages,
  lazily loads metadata/font off the main actor, returns immutable physical bits
  and maps all orientations to CGImage. Native errors/cancellation return no
  frame; explicit retry recreates the context. Five actual-bridge simulator
  tests and the full202 app tests pass; macOS and unsigned iPhoneOS builds pass
  (`.build/host-renderer-{focused,regression,mac,ios-device}.log`). Import verifier
  tests pass. No UI change, reader requests or uploads. Production font choice,
  preview UI, other surfaces and physical parity remain pending; see
  docs/HOST_RENDERER.md.

- 2026-09-22 sibling Apple renderer packaging now produces
  PocketUIHost.xcframework plus PROVENANCE.json, replacing the planned single
  archive/commit-only text receipt. All five macOS/iOS/simulator slices link a
  real Swift consumer; packaged macOS execution passes. Source hashes include
  dirty/untracked dependencies, and artifact hashes detect missing/changed files.
  Import must verify this provenance before copying into Support/PocketUIHost;
  runtime must use bundled accepted metadata, not require a user's sibling repo.
  No artifact has been imported into this app yet. App bridge/UI, iOS execution
  and physical parity remain pending; see both Live Studio contracts.

- 2026-09-22 sibling `host/` now builds an independent content renderer archive
  with a C ABI and Swift module map. A local macOS Swift consumer successfully
  renders/copies a Korean empty page and checks failed-request invalidation;
  24 C ABI page frames match direct rendering, alongside32 font-mode comparisons
  and326 firmware host tests. Rendering is serialized for upstream MiniBidi's
  shared scratch. This verifies interop, not the app bridge or iOS packaging.
  No host artifact/source was copied here; pinned Apple artifact sync, app
  preview UI, other native surfaces and physical goldens remain pending.
  Contract/API are in sibling `host/README.md` and `host/include/PocketUIHost.h`.

- 2026-09-22 sibling ContentPageRenderer is now shared by device and host text
  card/empty rendering.24 real-font frame comparisons match Cached/BoundedUI;
  firmware312 host tests, strict check and build pass. This is a common C++
  rendering boundary only, not the Swift bridge, packaged artifact, image-page
  parity or physical acceptance. No app binary/source import or device access.

- 2026-09-22 exact-preview foundation now exists in sibling `test/gfx_host`:
  production raster/font/shaping sources build on Mac with test HAL, and8 local
  text frames compare Cached/BoundedUI pixel-identically. This is not a Swift
  bridge, packaged host artifact, full theme surface or physical golden result.
  Real-font testing fixed multiline content preflight rejecting layout controls.
  Firmware309 host tests, strict check and local build pass. No firmware source
  or binaries copied to the app and no reader accessed; see Live Studio design.

- 2026-09-22 sibling firmware now suppresses live-frame publication for failed
  or queued content rendering; old valid captures remain historical. Swift
  still uses exact reader/revision/generation presentation receipts rather than
  treating a frame event as activation/display confirmation. Wire format is
  unchanged; see both Live Studio contracts. Firmware300 host tests, strict
  check and local build pass, not physical capture acceptance. No device access.

- 2026-09-22 full app unit regression now passes197 tests after the presentation
  integration and cancellation-observation fix
  (`.build/content-presentation-regression.log`). This supersedes the earlier
  focused-only rerun evidence. Includes mocked apply/redraw outcomes and local
  loopback transport tests, not live-device acceptance. No reader was contacted.

- 2026-09-22 local content presentation integration now follows confirmed
  activation with one paint POST and bounded read-only polls, preserving the
  selected File Transfer session. Mocked PocketModel success/failure tests prove
  no reupload, reactivation or session-end request and retain confirmed storage
  on redraw failure.23 focused app tests and iOS/macOS builds pass
  (`.build/content-presentation-{focused,mac}.log`). The earlier93-test run had
  one cancellation-observation race; a bounded wait for URLProtocol stop was
  added and that test passes in the focused rerun. No full rerun claim.
  Sibling288 host tests, strict cppcheck and default build pass. Presentation
  controller fault injection, framebuffer parity and physical acceptance remain
  outstanding. No reader access or firmware upload occurred.

- 2026-09-22 code inspection found File Transfer's active-Wi-Fi exit restarts
  the reader, so automatic `session/end` after each content Apply would recreate
  the reconnect loop. The chosen direction is a lightweight content view inside
  the existing selected transfer session; explicit session termination stays
  separate. Shared verified view data now lives in firmware `ContentViewState`
  and is used by the offline Pocket activity. Live hosting/render receipts and
  Swift integration were subsequently added as recorded above; physical
  acceptance remains unfinished. No reader was contacted.

- 2026-09-22 unreadable activation tracking has an explicit recovery path:
  parser/schema/size/field failures may be backed up byte-exactly before atomic
  reset; valid/absent records, I/O errors, directories and symlinks are refused.
  The editor exposes the error, confirmation and backup export. Demo cannot
  recover; recovery issues no deployment commands.27 journal/coordinator/
  admission tests and iOS/macOS builds pass
  (`.build/content-journal-recovery-{tests,mac}.log`). Persistent backup browsing
  and cross-process locking remain pending; no physical reader access.
  Full app regression subsequently passed188 tests; iPhone/iPad UI regression,
  three-platform screenshots and source-package validation also passed
  (`.build/content-journal-recovery-{regression,screenshots}.log`). Representative
  iPhone inspector screenshot inspected; these are not hardware acceptance.

- 2026-09-22 firmware preparation surfaces attempted-copy create/write/readback
  failure as HTTP503 with no receipt. App displays the SD/free-space guidance
  and makes one request, with no automatic fallback upload or activation.
  Source absence/mismatch still permits normal upload.28 related app tests and
  iOS/macOS builds pass (`.build/content-copy-failure-{tests,mac}.log`); sibling
  272 host tests, strict check and default build pass. This does not diagnose
  free capacity or complete quota/GC work; no physical device was contacted.

- 2026-09-22 pending activation checks can be explicitly archived after a separate
  confirmation. Exact record bytes are copied before clearing the matching
  intent; mismatch/failure retains unknown state. UI exports the archive and
  states that reader activation was not undone; no new Apply is automatic.
  Demo cannot archive.24 journal/coordinator/admission tests and iOS/macOS
  builds pass (`.build/content-archive-{tests,mac}.log`). Corrupt-record recovery
  and persistent archive browsing remain pending. No actual reader access.
  iPhone/iPad UI regression, three-platform screenshots and source-package
  validation pass (`.build/content-archive-screenshots.log`).

- 2026-09-22 content activation now uses an atomic local write-ahead journal
  before sending the activation command. Failed persistence prevents activation;
  unresolved/malformed records cannot be overwritten by a new deployment.
  Editor opening restores pending identity/revision/generation locally, with
  no network activity; demo skips restoration. Verified confirmation clears
  only the exact intent.26 journal/coordinator/adapter/admission tests and
  iOS/macOS builds pass (`.build/content-journal-{tests,mac}.log`). XcodeGen
  regenerated both targets. This supersedes in-memory-only recovery notes.
  Explicit archival/abandonment, cross-process locking and physical acceptance
  remain outstanding. No device access, upload or network reconfiguration.
  iPhone/iPad UI regression, all screenshot sets and source-package validation
  also pass (`.build/content-journal-screenshots.log`).

- 2026-09-22 ambiguous content activation can be resolved with “Check activation
  outcome”: one read against the currently selected address of the original
  reader, using the exclusive app session lane. Coordinator retains revision,
  capability requirement and prior generation; rejects mismatches/stale state,
  retains pending on read failure/cancellation, and never reuploads/reactivates.
  20 relevant tests and iOS/macOS builds pass
  (`.build/content-confirm-{tests,mac}.log`). Pending state is in-memory only;
  restart recovery and physical-screen confirmation remain unimplemented.
  No real reader access or network changes were performed.
  iPhone/iPad UI regressions, three-platform screenshot generation and source
  package validation pass (`.build/content-confirm-screenshots.log`).

- 2026-09-22 local draft recovery now requires explicit confirmation, preserves
  the existing regular file as a unique sibling backup before atomic replacement,
  and retains current edits. Backup export is user initiated; demo cannot recover.
  Recovery UUID plus generation prevents stale pre-recovery editors from saving
  over a new generation1.20 draft/image tests and iOS/macOS builds pass
  (`.build/content-recovery-{tests,mac}.log`). This is shared-actor protection,
  not cross-process locking or compatibility with old writers that ignore UUIDs.
  Backup browsing/import/comparison remains pending. No device access.
  Full app regression passes173 tests, including local loopback transfer cases
  (`.build/content-recovery-regression.log`). iPhone/iPad UI regression,
  three-platform screenshot generation and source-package validation also pass
  (`.build/content-recovery-screenshots.log`); these do not cover real reader I/O.

- 2026-09-22 firmware preparation can reuse unchanged active-revision assets:
  only a copied and rehashed staging file earns the existing schema1 verified
  bit. A new adapter regression proves text-card edits upload manifest/card but
  omit that verified unchanged image.26 related app tests and iOS/macOS builds
  pass (`.build/content-reuse-{tests,mac}.log`); sibling271 host tests and strict
  check/default build pass. No wire-format change or physical-device access.
  Historical/renamed-file reuse, GC and physical acceptance remain outstanding.

- 2026-09-22 content editor now exposes native image selection/replacement,
  reference-safe removal, and an off-main canonical-PBM pixel preview explicitly
  distinguished from reader layout. Import is local-only and closing the editor
  cancels pending attachment. This supersedes earlier picker/preview-pending
  notes.22 relevant tests and iOS/macOS builds pass
  (`.build/content-image-ui-{tests,mac}.log`); no live reader requests or uploads.
  iPhone/iPad flow tests, all three platform screenshot sets and the App Store
  source validator also pass (`.build/content-image-ui-screenshots.log`).

- 2026-09-22 ContentImageImport now provides bounded, off-main selected-file
  decoding to canonical PBM:20MiB input cap, <=512px oriented thumbnail,
  white alpha composition and fixed luminance threshold. Existing PBM is
  byte-exact. ContentEditorModel attaches validated output without saving or
  deploying, rejects changed/missing cards and filename collisions, and retains
  shared referenced images. File picker/preview UI remains pending.20 relevant
  tests (7 import/attachment) and iOS test/macOS builds pass
  (`.build/content-image-import-{tests,mac}.log`). No device access or source
  image mutation. Contract/limits: `docs/CONTENT_EDITOR.md`.

- 2026-09-22 sibling firmware now draws canonical PBM card images in the detail
  view's remaining text-to-hints area, using bounded row reads and existing
  theme/renderer integration. This supersedes notes that all PBM rendering is
  absent. No app wire-format change: ContentImage's existing P4 contract is
  reused. App image import/preview and actual-panel/screen confirmation remain
  pending; no device upload. See sibling `docs/content-display.md`.

- 2026-09-22 full app unit regression passes158 tests, including the6MiB
  loopback flow-control case (`.build/content-editor-unit-regression.log`).
  Added a further passing real PocketModel/URLProtocol regression that selects
  an identified reader, enters the owned content-transfer lane, receives the
  already-active revision and completes without any staging/upload/activation
  request; the success message still disclaims screen confirmation
  (`.build/content-apply-model-test.log`). No live device or network changes.

- 2026-09-22 the shared studio opens a text-card editor with add/edit/reorder/
  remove, UTF-8 validation, local draft save and confirmed Apply wired to
  PocketModel. Normal sheets reuse model-owned draft state; demo sheets are
  isolated and never load/save the normal draft or apply to a reader. Status
  labels distinguish storage activation from screen confirmation.10 draft/
  admission tests, standalone demo-editor UI test and iOS/macOS builds pass
  (`.build/content-editor-*`). iPhone/iPad UI regression, Mac render tests and
  regenerated10 store screenshots pass the source validator; editor and changed
  platform layouts inspected. The iPad test dismisses its keyboard before
  checking the lazy Form's disabled controls. QA captures are excluded from
  numbered store screenshot exports. Image import,
  conflict recovery UI and full physical acceptance remain pending. No device
  access or firmware upload. See `docs/CONTENT_EDITOR.md`.

- 2026-09-22 `PocketModel.applyContent` now runs ContentDeployment through the
  existing exclusive transfer task, with demo/background/identity/hardware/
  stream-capability admission, quiesced optional traffic and session-bound
  cleanup. Existing pause/background cancellation applies. Messages distinguish
  storage activation, uncertain activation and pre-activation cancellation.
  Draft save never invokes it. App admission, coordinator, adapter, draft and
  device-core tests plus iOS test/macOS builds pass (`.build/content-apply-*`).
  UI Apply binding and full app/device lifecycle acceptance remain pending;
  tests made no live reader requests. See `docs/CONTENT_DEPLOYMENT.md`.

- 2026-09-22 local authoring persistence now exists: ContentDraftStore is a
  bounded, schema-versioned, atomic JSON store actor with generation conflict
  checks; ContentEditorModel retains unsaved edits and separates save from
  validated deployment snapshots. Incomplete text can be saved, not deployed.
  Missing-file Cocoa errors4/260 are handled explicitly; corrupt/unsupported/
  oversized records cannot be silently replaced. See `docs/CONTENT_EDITOR.md`.
 31 relevant tests (7 new draft/editor), iOS test and macOS builds pass
  (`.build/content-draft-{tests,mac}.log`). SwiftUI controls and Apply binding
  remain pending. No network/device operations or firmware changes this step.

- 2026-09-22 firmware now loads fully verified active app-card text on Pocket
  activity entry into existing overview/detail/personal snapshot paths. Back
  closes these cards locally without a provider outbox action. This supersedes
  earlier notes that all boot/render integration is absent. PBM display and
  automatic transfer-to-reader transition/screen confirmation remain pending;
  content-state receipts still prove storage selection only. See sibling
  `docs/content-display.md`. No app wire-format change or device deployment.

- 2026-09-22 `ReaderContentTransport` now binds the deployment coordinator to
  CrossPointClient's atomic stream upload and content prepare/state/activate
  methods. It pins one revision/reader, stages the manifest, checks actual
  candidate hashes after each asset, and never changes networks. Fresh status
  identity and advertised stream-port checks precede file transfer; these are
  routing checks, not authentication. Existing bounded stream recovery remains.
 39 content tests and iOS test/macOS builds pass (`.build/content-adapter-*`).
  This supersedes older notes saying the adapter or activation API is absent.
  Editor/UI binding, firmware boot/render integration, cross-revision asset
  reuse, product authorization and physical acceptance remain incomplete.
  No reader was contacted or firmware uploaded.

- 2026-09-22 `CrossPointClient.inspectPreparedContent` now invokes the paired
  firmware prepare endpoint through ReaderHTTPTransport. It validates the
  expected eight-uppercase-hex identity before network access, uses revision/
  device query parameters and no-cache POST, rejects non-2xx/oversized/invalid
  receipts and does not automatically retry. URLProtocol tests cover the real
  client boundary;17 deployment/receipt/HTTP tests and iOS test/macOS builds pass
  (`.build/content-prepare-http-{tests,mac}.log`). Manifest staging and the full
  ContentDeploymentTransport adapter remain absent. No device was contacted.

- 2026-09-22 firmware exposes read-only content preparation inspection after
  manifest staging; Swift ContentPreparationReceipt maps verified bits to the
  exact local assets only after checking device/revision/count/schema/bounds.
  Contract: sibling `docs/content-prepare-v1.md`. No full transport adapter,
  activation endpoint, UI or capability advertisement yet.27 content tests,
  iOS test build and macOS build pass (`.build/content-prepare-{tests,mac}.log`);
  no physical device access.

- 2026-09-22 ContentDeployment adds the main-actor observable app coordinator:
  identity/capability gate, verified candidate-file diff, serial uploads,
  activation-once then state confirmation, generation checks and cancellation/
  overlap handling. Internal transport only, no HTTP adapter/endpoints/UI yet.
  See `docs/CONTENT_DEPLOYMENT.md` for required firmware mapping and limitations.
 24 content tests (10 deployment), iOS test build and macOS build pass
  (`.build/content-deployment-{tests,mac}.log`). No device access.

- 2026-09-22 sibling firmware rejects conflicting upload/file-mutation/commit
  requests while a file writer is live. HTTP conflicts return409; companion
  `CrossPointClient.requireSuccess` already rejects non-2xx and surfaces the
  response body. No Swift wire-format change or new capability; runtime
  simultaneous-client verification and content endpoint integration are pending.

- 2026-09-22 sibling firmware now reserves `/pocket-daily/content` and the two
  active-content records against generic network writes, including ancestor
  operations. Future content sync must stage under `/pocket-daily/content-staging`
  and use a dedicated seal/activate service (not yet implemented). Existing app
  book/UI-pack destinations remain outside this reservation. No app content
  transport or device capability is advertised yet; no hardware was changed.

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

## Implementation plan — 2026-09-21

- 2026-09-22 full revision golden now matches sibling's production read-only
  HAL verifier (real SHA via host crypto adapter, not a dummy hash). Candidate
  path `/pocket-daily/content/<manifest-sha256>/manifest.pdcm`. Verifier checks
  every file's size/hash/semantics and all card-image references, without writes.
  Contract: sibling `docs/content-revision-store.md`. Directory write exclusion,
  staging/activation/recovery, editor and device verification remain outstanding.
  Verification:14 content tests/iOS test/macOS build and sibling229 host tests,
  strict cppcheck/default build pass (`.build/content-store-*`, sibling `build/content-store-*`).

- 2026-09-22 local revision assembly: `ContentImage` implements canonical bounded
  P4 PBM (<=512x512, zero row padding); sibling validator uses64-byte row scratch.
  `ContentRevision` validates unique cards/complete image references, computes
  actual file hashes and manifest revision, preserves editor order in filenames
  and plans local changed files. No device receipt, upload, activation or UI yet.
  Contract: sibling `docs/content-image-v1.md`; shared9x2 golden.
  Verification:13 Swift content tests, iOS test/macOS builds pass; XcodeGen
  registered files. Sibling223 host tests, strict cppcheck/default build pass.
  Logs `.build/content-revision-*`, sibling `build/content-image-*`.

- 2026-09-22 PDCT v1: `ContentCard` encodes fixed512-byte reading cards with
  strict UTF-8 byte limits, identifier/image-path checks and CRC. Sibling
  allocation-free decoder maps text to existing Card, module=app/class=info,
  no choices. Same Korean golden/CRC; contract in sibling `docs/content-card-v1.md`.
  Image existence/bitmap semantics, editor, app-owned pool, local action routing
  and activation remain unimplemented; no capability advertised or device accessed.
  Verification:8 Swift card/manifest tests and iOS test/macOS builds pass;
  XcodeGen registered files. Sibling218 host tests, strict cppcheck/default
  build pass. Logs `.build/content-card-*`, sibling `build/content-card-*`.

- 2026-09-22 P3 foundation: `ContentManifest` produces canonical PDCM v1 file
  lists with length/SHA-256/path/capability metadata and CRC, plus a SHA-256
  revision. Sibling firmware has an allocation-free bounded structural parser;
  both pin the same golden. Contract: sibling `docs/content-manifest-v1.md`.
  No editor, active-content endpoint, file semantic validation or capability
  advertisement yet. Existing PDL/UI-pack contracts unchanged; no device access.
  Verification:4 Swift contract tests and iOS test/macOS builds pass; XcodeGen
  registered the two new Swift files. Sibling212 host tests, strict cppcheck and
  default build pass. Logs `.build/content-manifest-*`, sibling `build/content-manifest-*`.

- 2026-09-22 frame announcement validation: app decoder enforces firmware's
  UInt32 sequence domain and existing64..131072-byte fetch bound, rejecting
  JSON booleans (NSNumber bridging), fractional/out-of-range values and strings
  before scheduling.9 LiveSync tests, iOS test/macOS builds pass; sibling
  LiveStudioEvents tests pass and wire encoder signatures were checked.
  Logs `.build/frame-announcement-*`, sibling `build/frame-announcement-contract.log`.
  No firmware behavior or device access changed.

- 2026-09-22 accepted-session snapshot boundary: PocketModel now clears old
  preferences/dirty flag, screen and crash data before awaiting the newly
  accepted reader's preferences. New internal sessionStarted event clears the
  mirror atomically even when both old/new readers lack IDs; heartbeat status
  refresh remains distinct. Held-response model test verifies legacy view
  properties and mirror are empty while fresh preferences are pending. All15
  targeted tests and iOS test/macOS builds pass (`.build/session-snapshot-*`).
  No firmware contract or device action; complete binding migration remains open.

- 2026-09-22 mirror ownership: status events now refresh active pack/version;
  disconnect/search/wait/idle clears device-derived mirror fields, including
  pack state. Changed or lost device identity/model clears prior frame,
  preferences and progress without resetting the monotonic frame counter.
  Same-reader status keeps its captured frame. All13 DeviceCore tests and
  iOS test/macOS builds pass (`.build/mirror-ownership-*`). This repairs the
  shared mirror; migration away from legacy PocketModel view bindings and
  physical UI/connection acceptance remain incomplete. No device access.

- 2026-09-22 consolidated regression after HTTP admission and connection/
  foreground lifetime changes: all103 unit/integration and7 UI tests pass
  (`.build/lifecycle-full-regression.log`). Sibling188 host checks and42 Python
  uploader/benchmark tests pass. Corrected both Live Studio design documents:
  partial implementation, actual15s heartbeat/16KiB live-push admission, closed
  HTTP page connections, absent exact host renderer, local-vs-installed radio
  policy. No hardware requests/install or physical acceptance in this audit.

- 2026-09-22 foreground lifecycle: iOS scene activation now resumes the paced
  heartbeat only after backgrounding and only for an existing LAN session.
  Duplicate activation is inert; no discovery, Wi-Fi join, direct-lease resume
  or automatic file resend is introduced. Background state prevents completed
  operations from restarting live traffic. A held-response model test verifies
  the actual 15s heartbeat returns once on the saved endpoint; no-session
  activation and verification-background regressions also pass (3 tests), plus
  iOS test build/macOS build. Logs `.build/foreground-lifetime-*`. No device
  access; physical lifecycle acceptance remains outstanding.

- 2026-09-22 verification lifetime correction: manual HTTP verification now
  owns a cancellable task, drains prior background traffic, and guards result,
  error and busy-state cleanup by connection generation. Replacement, search,
  backgrounding and session finish cancel the old task; caller cancellation
  is forwarded. Backgrounding stops live traffic for LAN as well as direct
  sessions. Two held-response model tests plus the existing heartbeat-drain
  test pass, with iOS test build and macOS build (`.build/verification-lifetime-*`).
  No device requests or firmware changes; this is not radio-root-cause proof.

- 2026-09-22 small-file physical evidence: unchanged X3 `w998f2f9d` passed one
  1 KiB CLI stream/CRC/publication/downloaded-SHA/cleanup trial after omitting
  the failing optional statistics API. No firmware install, reconnect or user
  action. The file is smaller than the 4096-byte credit window, so multi-window
  transfer, resume and app-driven acceptance remain open. See
  `docs/CONNECTIVITY_VALIDATION.md`; diagnostic failure is not file-path failure.

- 2026-09-22 fresh read-only X3 status on the unchanged installed `w998f2f9d`
  returned HTTP 200 in 0.118802 s (uptime 1838 s, heap 9100 B, RSSI -45 dBm).
  This establishes intermittent rather than persistent unreachability, not a
  transport fix. No upload/reconnect/reboot was attempted. Corrected stale
  `CONNECTIVITY_VALIDATION.md` wording that still called this image uninstalled;
  the completed bootstrap must not be repeated from that historical note.

- 2026-09-22 HTTP admission: all shared CrossPointClient URLSession data calls
  now use a cancellation-aware per-host FIFO. Same-host HTTP cannot overlap
  across actor suspension; different hosts still run concurrently for LAN
  discovery. Tests cover queued cancellation without sending, active
  cancellation releasing the next request, and cross-host parallelism. All
  99 app unit/integration tests and iOS/macOS builds pass (`.build/http-serialization-*`).
  Bulk stream/multipart and WS retain model-level transfer ownership; this is
  not global operation serialization, a physical radio fix, or a new protocol.
  No device access or firmware install was performed.

- 2026-09-22 in-flight ownership verification: three additional model tests
  hold URLSession responses, observe cancellation of pending preview/settings,
  protect a newer operation from old completion, and verify the actual paced
  heartbeat is drained before a settings POST (no older active request).
  Five ownership tests pass in `.build/inflight-ownership-tests.log`.
  Test-only change; physical radio and idle background serialization remain
  unverified. No device access or firmware installation was performed.

- 2026-09-22 local app ownership correction: settings reserves busy state before
  scheduling, captures endpoint/generation and suppresses stale completion;
  settings and manual preview drain tracked background work before I/O, then
  resume paced heartbeat. Backgrounding cancels the operation; edits made
  during save remain dirty. Two new model/URLSession tests plus three discovery
  regressions pass, with iOS simulator test build and macOS build. This is not
  global idle-request serialization or physical connectivity verification.
  Logs: `.build/settings-ownership-tests.log`, `.build/settings-ownership-mac.log`.

- 2026-09-22 app scheduling audit: upload drains tracked optional tasks, but
  settings save does not reserve ownership synchronously or reject busy calls;
  manual preview does not drain in-flight reads. Independent background task
  slots are not a reader-wide scheduler. See `docs/TRANSPORT_RELIABILITY.md`
  for concrete interleavings and the local test gate. These are source-proven
  ownership gaps, not an explanation of CLI pre-payload failures. No device
  requests, upload or network changes were made during this audit.

- 2026-09-22 local firmware correction removes gateway-port-driven forced
  reconnect, restoring passive association observation/driver recovery with
  the existing sustained-loss grace. 188 host checks, strict cppcheck and
  default build pass. No app protocol change. Not uploaded or hardware-proven;
  installed `w998f2f9d` remains the baseline. Do not resume an upload loop on
  the strength of this local result alone.

- 2026-09-22 physical bootstrap now confirmed: same X3 reports exact
  `w998f2f9d` after SD installation and existing Join a Network mode. Small
  HTTP control requests subsequently failed/intermittently completed before
  any benchmark upload; radio/driver/resource cause is not yet isolated.
  Firmware benchmark document records evidence. No network-mode changes or
  further SD swaps were requested; preserve the user's current connection.

- 2026-09-22 hardware workflow constraint reinforced: minimize physical card
  swaps and do not keep trying different connection modes. Preserve the
  existing home-network STA workflow; use measurements rather than speculative
  mode changes. Instrumented firmware was staged and verified on SD with the
  previous update image backed up; this is not installation confirmation.

- 2026-09-22 full regression after the metric-domain changes: all 91 app
  unit/integration tests and 7 UI tests pass, including the 6 MiB flow-control
  test and deterministic no-reader discovery flow. Log:
  `.build/current-full-regression.log`. Current sibling gh_release also builds,
  passes the app's actual firmware validator and contains no developer flash/
  transfer-counter route markers; its 187 host and 36 Python tests pass.
  These are local checks, not physical radio/installation or release approval.

- 2026-09-22 actual-image cross-repo preflight: `scripts/validate_firmware.sh`
  compiles the shipping Swift firmware validator for read-only artifact checks
  with an explicit expected version. New `sta_recovery` `w998f2f9d` passes
  (6036272 bytes, SHA256 in `docs/CONNECTIVITY_VALIDATION.md`); wrong-version
  and missing-file checks fail. This is not installation or radio validation.

- 2026-09-22 resource-lifetime increment: sibling firmware now allocates the
  optional provider's volatile WS command queue only for a used connection and
  releases/clears it on disconnect. Pocket card state and durable SD choices
  are unchanged; no app protocol change. 187 firmware host checks, default
  build and strict cppcheck pass. This is partial P2 work, not proof the wireless
  delivery bottleneck is solved; installation and physical tests remain pending.

- 2026-09-22 metric-domain parity: encoder and sibling parser now require
  homeCoverHeight 1..2048 and popupTopOffsetRatio 0..1 (signed zero retained).
  Boundary-bit tests agree; existing mixed-type golden remains unchanged.
  10 Swift pack tests and iOS/macOS builds pass; sibling has 184 host checks,
  default build and strict cppcheck passing. Other metric/composed-layout
  bounds and physical apply/revert remain unverified. Device still runs the
  older firmware after the instrumentation-image wireless delivery failed.

- 2026-09-22 planning refinement: `docs/IMPLEMENTATION_PLAN.md` now maps the
  stages to explicit work packages, transport experiment branches, and the
  normal/developer automation boundary. Transport selection remains open until
  measured; SD is bootstrap/recovery rather than the routine workflow. This is
  planning only, not a new implementation or hardware verification result.

- 2026-09-22 renderer audit: firmware layout already read active pack metrics,
  but multiple native draw paths bypassed them via compiled theme constants.
  The sibling now routes those four theme implementations through active
  UITheme metrics and protects pagination divisors. Its 182 CTest checks,
  default build and strict cppcheck pass. This is not physical UI apply/revert
  verification or proof every field affects every theme; full metric bounds
  and pixel parity remain pending. No Swift wire format changed.

- 2026-09-22 value validation parity: firmware now rejects noncanonical bool
  words and Float32 NaN/infinity even with a valid CRC, matching the existing
  Swift encoder. Eight targeted Swift pack tests pass; sibling host suite is
  179 tests with default build and strict cppcheck passing. This is format
  validation, not a guarantee arbitrary finite metrics produce safe layouts;
  the new check has not been installed on hardware.

- 2026-09-22 UI pack activation: the app now publishes `studio-<revision>.uipack`
  with matching embedded name, preserving the current pack file until activation.
  Encoder/store agree on ASCII basenames <=24 bytes and versions <=16 bytes.
  Sibling firmware adds CRC/generation selection slots, boot fallback and runtime
  status truth, and adopts prepared metrics after checked persistence. See its
  `docs/live-studio-v1.md` for the storage contract. Eight targeted Swift pack
  tests and iOS/macOS builds pass; firmware host tests total 171 and default
  build/strict cppcheck pass. This is partial P3 work, not physical transaction
  sign-off; the new firmware was not installed during this increment.

- Discovery lifecycle follow-up: `ReaderDiscoveryIO` separates real LAN/Bonjour
  IO from the existing retry/state machine. The no-reader UI test now uses a
  DEBUG-only empty-IO fixture; production Release contains neither its class
  nor launch flag. Late/cancelled discovery cannot clear a newer attempt's work
  state or accept a Bonjour reply after backgrounding. Background cancellation
  releases the discovery work state. The repaired full run passed 88 unit/
  integration and all 7 UI tests; macOS Debug/Release builds passed. This fixes
  repeatability of the formerly real-LAN-dependent UI test, not proof of physical
  discovery latency/coverage. Full log: `.build/discovery-full-tests.log`.
  An additional targeted test then passed for a successful but late Bonjour
  status reply after background cancellation (`.build/discovery-late-status.log`).

- UI-pack contract repair: the Swift encoder now emits the registry's exact
  int/bool/float types, rejecting invalid values and truncated metadata. An
  identical full-pack fixture is checked against Swift output and the firmware
  host parser/metrics application. Apply/revert require same-reader exact active
  pack/version status before reporting success; unavailable status is unknown,
  not success or proof of rollback. Deployment revision is a 16-character UUID
  token, avoiding second-resolution timestamp reuse. 85 app unit/integration
  tests, iOS/macOS builds, 167 firmware host tests, default firmware build and
  strict cppcheck passed. Physical app-pack application and transactional
  multi-file activation remain open; no firmware was flashed in this increment.
  The full test invocation also ran UI tests: 6/7 passed, including demo screen
  capture, but `testDiscoveryWithoutAReaderFailsQuicklyAndSaysWhatToDo` failed
  waiting for its no-reader message. It uses real LAN discovery while an X3 is
  present; the precise UI/runtime cause is not yet established. Do not describe
  this invocation as an entirely green test suite. Log: local
  `.build/pack-contract-tests.log`.

- `docs/IMPLEMENTATION_PLAN.md` records the planned CrossPoint-core/Pocket-runtime
  boundary, measured transport selection, exclusive sync resources, transactional
  content/UI revisions, bounded UI definitions, and developer/product security
  gates. Start with baseline and transport measurements, not more UI services.
  This is a plan, not evidence that these features have been implemented.

## Wireless developer installation — 2026-09-21

- Sibling firmware `1.6.6-dev-main-b8e38e39-sta-recovery-w67fff974` passed full
  6030416-byte CLI upload, CRC-checked publication, developer flash and same-reader
  exact-version verification after automatic saved-Wi-Fi rejoin on X3. No
  post-flash menu action, SD swap, USB or hotspot was needed.
- This supersedes earlier unverified developer-flash/rejoin notes, not physical
  app/X4 acceptance. Post-install 64 KiB reception passed CRC, but throughput
  remained about 2.2 KiB/s. Low-memory/long-run stability remains open; production
  reader confirmation is unchanged. Firmware evidence is in its
  `docs/CORE_CONNECTIVITY_REPAIR.md`; no app source changed for this follow-up.

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

- 2026-09-21 physical X3 baseline: after one SD bootstrap, live STA status
  confirmed `1.6.6-dev-main-b8e38e39-sta-recovery-wf3e32596`. CLI transfer of
  6,030,352 bytes passed final CRC AE2A4752 and HTTP commit to `/update.bin`.
  An intentional sender interruption resumed at 1,187,840 bytes; the resumed
  segment used 512-byte/10 ms pacing within 4 KiB SD ACK windows. The reader
  remained responsive without reboot. App implements equivalent pacing;
  80 tests and iOS/macOS builds pass. App-driven hardware delivery, X4, and
  new-version developer flash/rejoin remain unverified. See
  `docs/TRANSPORT_RELIABILITY.md` for the evidence and throughput limitations.

- 2026-09-21 working-tree contract: transfer tasks cancel/drain optional reader
  traffic; bounded LAN recovery verifies device identity; a healthy heartbeat
  restores a stopped live socket. `uploadStreamWindow:4096` negotiates SD-ACK
  flow control with the sibling firmware, preserving legacy stream support.
  Resume remains RAM-only on the reader. See `docs/CONNECTIVITY_VALIDATION.md`
  for physical acceptance; local tests are not hardware sign-off.
  The firmware now separates Pocket Sync's shared-Wi-Fi COMPANION profile
  from browser File Transfer, exposing preferences and UI packs without the
  browser route/discovery allocations. Firmware creates missing upload parent
  directories for first-time content/pack delivery.

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

## M2/M3 shipped — 2026-09-19

- M2 (`9e0e4ef`): LiveSyncClient (URLSessionWebSocketTask) subscribes after
  hello and streams reader frames into the existing canvas;
  FrameFetchPolicy coalesces and paces fetches (>= 1 s spacing) per the
  zombie lesson; preferences reload on prefsChanged.
- M3 (`34b5dc4`): UiPackEncoder mirrors the .uipack container (120-byte
  header after the offsets fix in the firmware repo, `d03558de`); the
  63-field registry is pinned by test; ThemePackInspector offers Apply live
  / Revert over the verified transfer path. Demo mode stays non-mutating.
- 65/65 unit tests. Device end-to-end demo (apply -> frame diff -> revert)
  pending a stable reader link; the firmware offsets build must be flashed
  first - see the firmware memory for the blocked-session details.

## M1 device core seam — 2026-09-19

- `Sources/Core/DeviceCore.swift` landed: `DeviceEvent`/`DeviceState` with a
  pure reducer, `DeviceMirror` (the observable snapshot), `DeviceSession`
  (the transport seam, MainActor), and `SyncModePolicy` mapping the reader's
  `liveStudio` advertisement to offline/poll/push. `CrossPointStatus` decodes
  the optional `liveStudio {wsPort, mode, frameStream, uiPacks, activePack*}`
  object; absent means legacy poll-only.
- `PocketModel` conforms to `DeviceSession` and feeds the mirror from its
  existing transitions (status, preferences, frames, transfer progress,
  connection phases). Views are unchanged — they migrate in M2/M3.
- Verified: 55/55 iOS unit tests (10 new in `Tests/DeviceCoreTests.swift`),
  macOS build clean. Firmware counterpart LS-1 landed in the sibling repo.

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
  the only project instruction file (constitution and workflow) and this file
  is the shared cross-agent memory. No agent keeps a private instruction file
  or separate memory.
- 2026-09-24: `CLAUDE.md` was folded into `AGENTS.md` and removed, because
  Claude Code 2.1.277+ reads `AGENTS.md` natively but only when no
  `CLAUDE.md`/`CLAUDE.local.md` exists in the working directory or above.
  Do not reintroduce either file.
- On 2026-09-19 the working tree held verified but uncommitted work dated
  2026-09-06 through 2026-09-09 (direct sessions, LAN discovery pacing, the
  screenshot pipeline, and App Store submission updates) while `origin/main`
  stopped at the firmware install-check change. Dated sections in that range
  describe that pending change set, not a pushed baseline.

## Explicit direct sessions — 2026-09-09

- Find & Connect is LAN-only. Connect Directly explicitly authorizes BLE/AP
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
