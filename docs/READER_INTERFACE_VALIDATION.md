# App–reader interface acceptance

The interface is not considered complete merely because a build or a single
upload passes. This matrix separates deterministic fault tests, actual app/X3
transactions, and acceptance that needs additional hardware or OS facilities.

## Repeatable unattended run

From this checkout:

```sh
python3 scripts/verify_reader_interface.py --standby --screenshots
```

This runs all shared app unit tests, the Mac reader and firmware-XPointer
cross-check, the enrolled reader's physical interface suite, optional screenshot
capture, and package validation. Logs and the aggregate JSON report are kept in
`.build/interface-runs/`. A skipped physical test, missing case, wrong run/version,
or cleanup failure cannot produce a passing hardware report. No firmware is
installed by this command. Omit `--standby` for firmware without experimental X3
BLE standby; add `--ios-device <udid>` to run the same supported cases on a physical
iPhone. Device results remain separate from simulator results.

Initial prerequisites are the existing developer-pipeline enrollment, compatible
developer firmware with `transferState` v1, Same Wi-Fi, granted OS permissions and
a signed Debug app. The normal companion must be closed so the test host is the
only owner of HTTP/Bluetooth. In an agent-led run the agent closes it, not the
user. Once started, no reader or app buttons are required. Pairing prompts,
unlocking a protected iPhone, and supplying an absent X4 are not simulated away.

For just the hardware portion:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" --interface-suite
```

If a UI capture run is interrupted after one device group completed, retain its
result bundle/summary and continue only the remaining groups, for example:

```sh
POCKET_SCREENSHOT_PLATFORMS='ipad mac' ./scripts/capture_screenshots.sh
```

The default still runs `iphone ipad mac`. Partial selections do not establish
coverage for omitted groups; keep their completed evidence separately. The
aggregate runner allows 60 minutes for full UI flows and captures.
Capture summaries persist under `.build/screenshots/capture-reports/` by default,
or the aggregate run's `ui-results/`. Interrupted runs retain their temporary
result bundles. A missing, failed or zero-test result is not accepted as a pass.
Run UI suites sequentially, including other projects using the same host's
simulators; concurrent automation caused long snapshot/diagnostic stalls during
acceptance. Preserve interrupted results and reuse individually passing capture
attachments only when the shipping UI sources have not changed.

The physical-only aggregate also runs the shared Wi-Fi setup, BLE protocol/link,
foreground wake, device snapshot, reader shelf and pixel-oracle unit tests on
macOS. These use deterministic fakes; the subsequent enrolled X3 stage supplies
actual radio and device evidence.

## Physical X3 screen validation

App screenshots are not reader-screen evidence. The prior ten-case suite only
read settings/profile values back; it did not capture the X3 display.

Use the physical-only aggregate (no simulator, no release preparation):

```sh
python3 scripts/verify_reader_interface.py --physical-only --screen-suite
```

Or run only the app/X3 baseline and screen cases:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" --screen-suite
```

The enrolled X3 must have the developer `dev/screen-capture`, `dev/reader-capture` and timer-enabled `dev/ble-cycle` endpoints. This
option does not flash; the developer pipeline's separately authorized firmware
installation prepares that prerequisite.

The running app's `sendReaderLayout(..., show:)` saves and presents each profile.
Only a matching completed generation can be captured. Under the renderer lock,
the reader saves its actual B/W framebuffer as BMP on SD, then serves bounded
pieces. The Mac saves and decodes that file, exports PNGs, rejects wrong runs
and stale generations, and rejects frames with only a header/footer before checking content-region changes:

- Home reading → daily word → reading: changed pixels, then exact restoration.
- Home weather off → bottom → top: visible layout changes.
- Daily Brief weather → today → weather: changed pixels, then exact restoration.
- Cards: apply two asymmetric PBM rasters with identical text through the app's
  actual content deployment; capture A → B → A. Require each exact raster in
  the captured page, reject the other raster, require changed pixels and exact
  restored pixels, then restore the saved original cards.
- EPUB: generate an isolated book, send it through the real book-transfer job,
  request the developer's run-bound reader activity, capture a completed EPUB
  page and automatically return to Same Wi-Fi. OCR requires three known body
  paragraphs. The original open book and recent-book list are not changed;
  existing reading records/order must compare equal after the suite.
- Actual sleep: present Today-only Brief, request a uniquely numbered timer
  cycle, capture the actual retained frame immediately before power-down, and
  reconnect without user input. Require the matching completed cycle,
  `returnMode=1`, `timerArmed=true` and `timerWake=true`; a restart or merely
  drawing the Brief is not a pass. OCR checks the retained Today content.
- Home and Daily Brief must differ. Clock/header and button footer are excluded
  from pixel equality, so a minute tick cannot stand in for a layout change.

Each saved BMP has a SHA-256 and run/generation/surface metadata. The firmware
runner exports XCTest attachments into its private run directory and verifies their
hashes; it does not require access to the app sandbox directory.
Missing images, a skipped case, restoration failure, or stale evidence fails the
run. Original profiles and failed captures remain locally for recovery; successful
captures and the owned EPUB are removed from the reader, original cards are restored, and the original profile is presented again. The suite exports 13 BMP/PNG pairs. Reader captures retain the configured reading orientation in native panel coordinates.
Inventory restoration compares every path and size, except the byte count of the
existing firmware-owned `/agentdeck.log`, which changes during boot/sleep. Removing
that log, adding files, or changing any other file size still fails the run.

After image export, `scripts/verify_reader_screens.swift` runs local Apple Vision
OCR: it requires the Daily Word label, verifies the forecast weekday row is on
the requested side of that card, and requires readable event times or a "No saved
events" explanation in Today-only Brief and the actual sleep frame. It also checks unchanged card text and the generated EPUB paragraphs. These anchors support English/Korean;
unreadable or unsupported text fails rather than silently skipping. The blank
pre-fix X3 capture is rejected by this checker; the repaired capture passes.
No images or recognized text are sent to a network service.

These are pixel and semantic-anchor checks, not an approved golden-image comparison:
a layout can still be unattractive while satisfying them. Review the exported
PNGs when changing layout expectations. The capture is the retained framebuffer
after the real display call; it does not measure optical ghosting, panel damage,
grayscale overlays or physical button navigation. The real reader test covers
the first fixture page, not every EPUB, font, orientation or page turn. The sleep
case proves timer deep sleep and retained rendering, not battery life. BLE standby
is a separate `--standby` case and requires battery strictly above 10% (above 5% on X3 while charging is confirmed).
Keep those gaps visible rather than labeling the whole product visually verified.

## Physical scenarios

`HardwareTests/ReaderInterfaceSuite.swift` drives the running shipping app model,
not a second model or a replacement transport. It creates an isolated Library
and refuses to replace any file present in the initial inventory.

| Case | Required observation |
| --- | --- |
| Identity rejection | Wrong identity receives the explicit identity-mismatch response; a network failure is not a pass. |
| SD usage | The app finishes the chunked SD scan, reports the same reader and valid capacity/free space, with no error. |
| Reading settings | Change a supported setting through the app, read values from the reader, restore and read back the original; preserve local drafts. |
| Home/Sleep profile | Save changes, check profile and generation, reject a stale-generation write, restore original values. |
| Books and articles | Prepare a real two-item app job, publish to root and `/Articles`, download through the app, compare every byte and imported document identity. |
| Downloaded book reading | Open the downloaded EPUB in the actual reading engine, obtain contents/XPointer, turn a page, restore its first position. This is app pagination, not optical proof of the physical reader. |
| Pause/resume | Wait for actual streaming progress below completion, pause, retain the resumable job, finish, and compare downloaded bytes. |
| Pause/discard | Pause another owned transfer, discard local/remote staging through the app, verify idle feedback and that its earlier published book still has identical bytes. |
| Folder copy | On Mac, copy books/articles through the real SD-folder code into a temporary directory and compare bytes. This does not prove a physical card mount/eject. |
| Inventory preservation | Delete only this run's published paths with their expected sizes; require initial and final unrelated file inventories to match. |

The baseline also reconnects through the app, checks identity/version and paginated
inventory, and tests a small EPUB round trip. `--standby` adds actual developer
standby, app BLE wake, network return and firmware memory/cycle evidence. No
status probe is introduced during the bulk upload lane.

Settings/profile originals are saved before mutation in the isolated recovery
directory. Failures attempt restoration and owned-job/file cleanup, preserve
diagnostics, and fail the run. Unknown outcomes are not blindly replayed. Reports
include the recovery path on failure. Completed job history can remain in the app;
the harness does not erase user history or unrelated pending tasks.

### Findings from actual X3 image review

- A Today-only Daily Brief had no body when no events were saved. It now shows
  a localized "No saved events" explanation; a frame containing only header and
  footer fails the physical pixel check.
- Brief section headers advanced by the small Latin font's height even when a
  larger CJK font rendered the label, crowding the weather temperature. Headers
  now use their resolved font line height. Host regression tests failed on the
  old implementation and pass with the correction; the app preview imports the
  same updated painter.

## Interface and failure coverage

| Feature/contract | Automated coverage | Remaining physical acceptance |
| --- | --- | --- |
| Identity, discovery, cancellation, reconnect | DeviceSnapshot, ReaderWakeConnector, NearbySyncProtocol, ReaderFleet tests; actual X3 connection/BLE cycle | X4 and multiple physical readers concurrently |
| Files, inventory, downloads | ReaderShelf/InventoryModel/FileDownloader tests; actual batch/byte comparison | Sudden physical SD removal or card failure |
| Transfers and receipts | BookTransferJob, BookSDCopy, TransferSeparation, ContentPreparation tests; actual pause/resume/discard | Router outage at publication boundary on each platform |
| Settings/profile drafts and conflict handling | ReaderPreferences, PocketProfile, ProfileMerge, ProfileDraftPersistence, ReaderLayoutSend tests; actual readback/restore | Visual effect of every orientation/font on X4 |
| Cards, images, activation and presentation | ContentCard/Manifest/Revision/Deployment/ActivationJournal, ReaderContentPull/Transport, ContentPresentation/ScreenPresentation tests | Physical card A-B-A raster/presentation with restoration in --screen-suite; physical Back-button return remains separate |
| Weather/calendar | ReaderGlance and layout-send tests with bounded fixtures | Live provider/network failures and reader rendering |
| Reading and continuation | ReadingSync, ReadingSyncBLE, ReaderEngine; Mac firmware-XPointer cross-check; actual downloaded EPUB pagination | Accepting the reader's position offer, physical iCloud multi-device delivery |
| Direct connection | NearbySyncProtocol and connection state/lease tests | iOS hotspot association, permission refusal, lease release |
| Firmware update | FirmwareGuidance/Release, atomic transfer separation; developer pipeline install/version verification when explicitly requested | Shipping second confirmation, recovery and X4 installation |
| Demo/privacy/offline behavior | Shared unit and UI suites; demo stays non-mutating | TestFlight entitlements and first-install permissions |

## Findings corrected in this iteration

- Partial inventory failures were silently ignored. Missing optional folders
  (404) are now empty; other failures retain useful files but show an incomplete
  warning. Non-terminating pagination fails instead of presenting a truncated
  result as complete.
- `/Books` files were omitted from the shelf, so recent books lacked their file
  size and could not be imported. Include this folder and merge FAT paths without
  case sensitivity (`/books` vs `/Books`) while retaining the enumerated path.
- X3 SD-usage requests returned 503 because the SDK allocation read depended on
  the disabled USB block-device interface. The firmware-owned SDK patch reads
  directly through its mounted SPI card, still serialized by `HalStorage`.
  An actual-header regression test covers USB-disabled SPI, unmounted/missing
  cards and I/O failure; reintroducing the old implementation fails the test.
- UI acceptance now measures connection actions against the containing sheet,
  not the full iPad screen. The offline draft-preservation scenario disables
  external discovery and verifies both the initial edit and the draft after
  returning from connection before checking section-specific discard.

Keep current measured results in `CURRENT_HANDOFF.md`. These automated results
are evidence for the named scenarios, not an App Store or whole-product release
approval.
